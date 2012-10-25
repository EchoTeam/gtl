The GTL - yet another logger.
----------------------------

Rationale
---------
If you have a complex data and control flow, and want to see what's happening
in your system  when some API function has been called, how does your system 
process this call - GTL is the best way to do it. 
With the help of GTL you can monitor not only current process and its data
but also see the whole picture:
- what node does the function work on and what is the pid of the process
- where the current function was called from, with what arguments,
  what was the pid and the node of the caller
    (not only for the nearest caller, but for the any depth caller)
- what is the timestamp of each logging print. As a result if you 
  print log in each logical phase, you could calculate the amount of time 
  each phase has spent.
- GTL wouldn't harm your cluster as it contains resourse management system.
  It wouldn't use more processes or memory then you allowed it to use 
    (see quota_server.erl)
- not saying a word about usual logging features


How does it works
-----------------

For each process you want to monitor (a worker), 
a new process (a logger) is created.  It gathers all the logs for the worker
until it dies. If it spawns a new worker (or somehow create new process), 
new logger is created for it.
When the child worker is died, its logger sends all the logs he's gathered
to the parent's logger. 
Info about the logger could be passed by:
- spawn <pre>see gtl:spawn/1</pre>
- rpc:call <pre>see gtl:rpc/4</pre>
- AMQ messages <pre>see gtl:get_clerk_info/0 plus gtl:set_clerk_info/1</pre>
- gen server calls (-//-)

So as a result you would see smth like the following
picture:

![Workers and loggers](https://github.com/EchoTeam/gtl/raw/master/graphics/workers-and-loggers.png "Workers and loggers")

Boxes here are the workers, and the circles are the loggers.

When all workers have died, the 'main logger' possesses all the logs.
So it decides if they should be saved or not. If not, the logger simply dies, 
forgetting the stored info. If any logger has marked his log (= flagged it) as
a worth attention, the whole bunch of logs are saved.
So it works like a transaction, when you first collect all the info you can,
and then either forget it or save it all.

On the picture above the flag 'worthy' is drawn with red color. 
At first it was set by the worker-5, then it is 
transfered to the logger of worker-4, then to 2, then to 'main logger' 1. When 
all the workers are dead, the log collected will be saved to some file.

Besides just reading the file as a plain text, it might be processed to the 
graphical view with the gtl-analyzer tool. The result file could look like this:

![Graphic representation of GTL logs](https://github.com/EchoTeam/gtl/raw/master/graphics/svg-example.png "Graphic representation of GTL logs")


(NB: it's old version of graphic representation, link to the new one could 
found below)

Try it
------

GTL does a great stuff, 

You could check it right now in console:
<pre>
bash $ make
bash $ ./start.sh
erlang> F = fun() -> gtl:log({a,b,"hello1"}), gtl:spawn( fun() -> gtl:log({a,c,"hello2"}) end), gtl:mark("bbb") end.
erlang> spawn(F).
=INFO REPORT==== 9-Jul-2012::01:18:37 ===
save log to "gtl.bbb.log" dir:"/Users/gli/projects/gtl"
erlang> ctrl-C
bash $ cat gtl.bbb.log 
[Sun, 08 Jul 2012 21:18:37 GMT; 1341782317.866] gtl version=0.1
[
 {"0.1",<0.52.0>,nonode@nohost,{1341,782315,856762},"2012/07/09 01:18:35",{a,b,"hello1"}},
 {"0.1",<0.52.0>,nonode@nohost,{1341,782315,859761},"2012/07/09 01:18:35",{gtl,marked,"bbb"}},
 {"0.1",<0.52.0>,nonode@nohost,{1341,782315,861202},"2012/07/09 01:18:35",{gtl,handle_down_client,<0.50.0>}},
 {"0.1",<0.52.0>,nonode@nohost,{1341,782315,861233},"2012/07/09 01:18:35",{gtl,register_child,<0.55.0>}},
 {"0.1",<0.55.0>,nonode@nohost,{1341,782315,859807},"2012/07/09 01:18:35",{a,c,"hello2"}},
 {"0.1",<0.55.0>,nonode@nohost,{1341,782315,861383},"2012/07/09 01:18:35",{gtl,handle_down_client,<0.54.0>}},
 {"0.1",<0.55.0>,nonode@nohost,{1341,782316,863118},"2012/07/09 01:18:36",{gtl,handle_stop_clerk,<0.55.0>}},
 {"0.1",<0.52.0>,nonode@nohost,{1341,782316,863437},"2012/07/09 01:18:36",{gtl,handle_down_child,<0.55.0>}},
 {"0.1",<0.52.0>,nonode@nohost,{1341,782317,865083},"2012/07/09 01:18:37",{gtl,handle_stop_clerk,<0.52.0>}}
]
</pre>

With the applied haskell-tool you could transfer it to the svg:
<pre>
bash $ ./gtl-analyzer --svg -i0 ./gtl.bbb.log > out.html
</pre>
I've saved it as a graphics/out.html file, download it and see the result.
