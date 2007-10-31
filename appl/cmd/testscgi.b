implement Testscgi;

include "sys.m";
	sys: Sys;
include "draw.m";
include "env.m";
	env: Env;

print, sprint: import sys;


Testscgi: module {
	modinit:	fn(): string;
	init:	fn(nil: ref Draw->Context, nil: list of string);
};

modinit(): string
{
	sys = load Sys Sys->PATH;
	env = load Env Env->PATH;
	return nil;
}

init(nil: ref Draw->Context, nil: list of string)
{
	if(sys == nil)
		modinit();

	print("Status: 200 OK\r\n");
	print("content-type: text/plain\r\n\r\n");
	for(l := env->getall(); l != nil; l = tl l) {
		(key, val) := hd l;
		print("%q=%q\n", key, val);
	}
}
