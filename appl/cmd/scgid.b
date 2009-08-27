implement Scgi;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "arg.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "string.m";
	str: String;
include "lists.m";
	lists: Lists;
include "env.m";
	env: Env;
include "daytime.m";
	daytime: Daytime;
include "dict.m";
	dict: Dictionary;
	Dict: import dict;
include "wait.m";
	wait: Wait;
include "sh.m";

Scgi: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};


nthreads := 3;
dflag := 0;
vflag := 0;

Scgicmd: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};

Cmd: adt {
	addr, modpath: string;
	mod:	Scgicmd;
	argv:	list of string;
	mtime:	int;
};


init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	bufio = load Bufio Bufio->PATH;
	str = load String String->PATH;
	lists = load Lists Lists->PATH;
	env = load Env Env->PATH;
	daytime = load Daytime Daytime->PATH;
	dict = load Dictionary Dictionary->PATH;
	wait = load Wait Wait->PATH;
	wait->init();

	arg->init(args);
	arg->setusage(arg->progname()+" [-dv] -[n nthreads] file\n");
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	dflag++;
		'n' =>	nthreads = int arg->earg();
		'v' =>	vflag++;
		* =>	arg->usage();
		}
	args = arg->argv();
	if(len args != 1)
		arg->usage();

	# read config file, with: address modpath argv
	path := hd args;
	(cmds, err) := readconfig(path);
	if(err != nil)
		fail("reading config: "+err);

	# reaper, refills the thread pool
	workchan := chan[2*nthreads] of (ref Sys->FD, Scgicmd, list of string);
	spawn reaper(workchan);

	# load modules from config file and spawn listeners
	netchan := chan[2*nthreads] of (ref Sys->FD, int);
	for(i := 0; i < len cmds; i++) {
		cmd := cmds[i];
		cmd.mod = load Scgicmd cmd.modpath;
		if(cmd.mod == nil) {
			warn(sprint("loading command %s: %r", cmd.modpath));
			continue;
		}
		cmd.mtime = mtime(cmd.modpath);
		say(sprint("set modpath=%s i=%d", cmd.modpath, i));
		spawn listen(cmd.addr, i, netchan);
	}

	# wait for activity from listeners
	for(;;) {
		(fd, cmdi) := <- netchan;
		cmd := cmds[cmdi];
		newmtime := mtime(cmd.modpath);
		if(cmd.mod == nil || newmtime && newmtime > cmd.mtime) {
			newmod := load Scgicmd cmd.modpath;
			if(newmod == nil) {
				warn(sprint("loading new version of module %s: %r", cmd.modpath));
			} else {
				cmd.mod = newmod;
				cmd.mtime = newmtime;
			}
		}
		say("to workchan modpath: "+cmd.modpath);
		if(cmd.mod == nil)
			warn(sprint("no module loaded for i=%d modpath=%s", cmdi, cmd.modpath));
		else
			workchan <-= (fd, cmd.mod, cmd.argv);
		fd = nil;
	}
}

mtime(path: string): int
{
	(ok, dir) := sys->stat(path);
	if(ok != 0)
		return 0;
	return dir.mtime;
}

readconfig(path: string): (array of ref Cmd, string)
{
	bio := bufio->open(path, bufio->OREAD);
	if(bio == nil)
		return (nil, sprint("opening %s: %r", path));

	cmds: list of ref Cmd;
	for(;;) {
		line := bio.gets('\n');
		if(line == nil)
			break;
		if(line[len line-1] == '\n')
			line = line[:len line-1];
		line = str->drop(line, "\r\t ");
		if(line == nil || line[0] == '#')
			continue;
		tokens := str->unquoted(line);
		if(len tokens <3)
			return (nil, sprint("invalid line, too few tokens: %q", line));
		cmds = ref Cmd(hd tokens, hd tl tokens, nil, tl tl tokens, 0)::cmds;
	}
	return (l2a(lists->reverse(cmds)), nil);
}

reaper(workchan: chan of (ref Sys->FD, Scgicmd, list of string))
{
	name := sprint("/prog/%d/wait", sys->pctl(0, nil));
	wf := sys->open(name, sys->OREAD);
	(nil, waitchan) := wait->monitor(wf);

	for(i := 0; i < nthreads; i++)
		spawn worker(workchan);
	for(;;) {
		<- waitchan;
		spawn worker(workchan);
	}
}

worker(c: chan of (ref Sys->FD, Scgicmd, list of string))
{
	(fd, mod, argv) := <- c;
	{
		execute(fd, mod, argv);
	} exception e {
	"*" =>
		if(vflag)
			warn(sprint("exception: %s", e));
	}
}

execute(fd: ref Sys->FD, mod: Scgicmd, argv: list of string)
{
	t1, t2, t3: int;

	if(vflag > 1)
		t1 = sys->millisec();

	(ns, err) := readnetstr(fd);
	if(err != nil) {
		say("readnetstr: "+err);
		return;
	}
	d: ref Dict;
	(d, err) = readheaders(ns);
	if(err != nil) {
		say("readheaders: "+err);
		return;
	}

	sys->pctl(sys->FORKENV|sys->NEWFD|sys->FORKNS, list of { 2, fd.fd });
	if(sys->dup(fd.fd, 0) == -1)
		raise "fail:dup";
	if(sys->dup(fd.fd, 1) == -1)
		raise "fail:dup";
	for(keys := d.keys(); keys != nil; keys = tl keys)
		env->setenv(hd keys, d.lookup(hd keys));
	if(env->getenv("QUERY_STRING") == nil)
		env->setenv("QUERY_STRING", "");

	fd = nil;
	
	if(vflag > 1)
		t2 = sys->millisec();
	mod->init(nil, argv);
	if(vflag > 1) {
		t3 = sys->millisec();
		warn(sprint("%-20s %5d ms   %5d ms", hd argv, t3-t2, t2-t1));
	}
}

listen(addr: string, cmdi: int, netchan: chan of (ref Sys->FD, int))
{
	conn: Sys->Connection;
	for(;;) {
		aok: int;
		(aok, conn) = sys->announce(addr);
		if(aok < 0) {
			warn(sprint("announce %s: %r", addr));
			sys->sleep(1*1000);
			continue;
		}
		break;
	}

	for(;;) {
		(ok, c) := sys->listen(conn);
		if(ok < 0) {
			warn(sprint("listen %s: %r", addr));
			sys->sleep(10*1000);
			continue;
		}
		dfd := sys->open(c.dir+"/data", sys->ORDWR);
		if(dfd == nil) {
			warn(sprint("open data file: %r"));
			continue;
		}
		say(sprint("listen: have connection addr=%s cmdi=%d", addr, cmdi));
		netchan <-= (dfd, cmdi);
		dfd = nil;
	}
}

readnetstr(fd: ref Sys->FD): (array of byte, string)
{
	n := 0;
	for(;;) {
		a := array[1] of byte;
		sys->read(fd, a, 1);
		c := int a[0];
		if(c >= '0' && c <= '9') {
			n = 10*n + (c - '0');
			continue;
		}
		if(c != ':')
			return (nil, "missing semicolon");
		break;
	}
	a := array[n+1] of byte;
	have := sys->read(fd, a, n+1);
	if(have != n+1)
		return (nil, "read too few bytes");
	if(a[n] != byte ',')
		return (nil, "missing closing comma");
	return (a[:n], nil);
}


writenetstr(a: array of byte): array of byte
{
	alen := sys->aprint("%d:", len a);
	r := array[len alen + len a + len array of byte ","] of byte;
	n := 0;
	r[n:] = alen;
	n += len alen;
	r[n:] = a;
	n += len a;
	r[n:] = array of byte string ",";
	return r;
}


findchar(a: array of byte, b: byte): int
{
	for(i := 0; i < len a; i++)
		if(a[i] == b)
			return i;
	return len a - 1;
}


readheaders(a: array of byte): (ref Dict, string)
{
	l: list of string;
	while(len a > 0) {
		i := findchar(a, byte '\0');
		l = string a[:i] :: l;
		a = a[i+1:];
	}

	if(len l % 2 != 0)
		return (nil, "odd number of values");

	d := ref Dict;
	while(l != nil) {
		v := hd l;
		l = tl l;
		k := hd l;
		l = tl l;
		d.add((k, v));
	}
	return (d, nil);
}


skip(l: list of string, bad: string): list of string
{
	if(l == nil)
		return l;
	if(hd l == bad)
		return skip(tl l, bad);
	return hd l :: skip(tl l, bad);
}


writeheaders(d: ref Dict): array of byte
{
	rlen := 0;
	for(keys := d.keys(); keys != nil; keys = tl keys) {
		(k, v) := (hd keys, d.lookup(hd keys));
		rlen += len array of byte k + 1;
		rlen += len array of byte v + 1;
	}

	r := array[rlen] of byte;
	n := 0;
	keys = d.keys();
	if(d.lookup("CONTENT_LENGTH") != nil)
		keys = "CONTENT_LENGTH" :: skip(keys, "CONTENT_LENGTH");
	for(; keys != nil; keys = tl keys) {
		(k, v) := (hd keys, d.lookup(hd keys));
		l2 := list of { k, v };
		for(q := l2; q != nil; q = tl q) {
			r[n:] = array of byte hd q;
			n += len array of byte hd q;
			r[n] = byte '\0';
			n += 1;
		}
	}
	return r;
}

l2a[T](l: list of T): array of T
{
	a := array[len l] of T;
	i := 0;
	for(; l != nil; l = tl l)
		a[i++] = hd l;
	return a;
}

warn(s: string)
{
	sys->fprint(sys->fildes(2), "%d %s\n", daytime->now(), s);
}

say(s: string)
{
	if(dflag)
		warn(s);
}

fail(s: string)
{
	warn(s);
	raise sprint("fail:%s", s);
}
