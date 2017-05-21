module profdump;

import std.stdio : File;
import std.string : indexOfAny, indexOfNeither;
import std.conv : to;
import std.regex : regex, matchFirst, replaceAll;
import std.json : JSONValue;

alias HASH = ubyte[4];

private char[] demangle(const(char)[] buf, bool verbose = false) {
	static import core.demangle;
	if(buf == "_Dmain".dup) {
		return "void main()".dup;
	} else {
		if(verbose) {
			return core.demangle.demangle(buf);
		} else {
			return core.demangle.demangle(buf)
				.replaceAll(regex(r"(?:@\w+\s|pure\s|nothrow\s)", "g"), "")
				.replaceAll(regex(r"\([ ,*A-Za-z0-9\(\)!\[\]@]+\)", "g"), "(..)");
		}
	}
}

struct Profile {
	Function[HASH] Functions;
	ulong TicksPerSecond;
	float TimeOfMain;

	this(ref File f, bool verbose = false) {
		import std.digest.crc : crc32Of;

		Function temp;
		bool newEntry = false;
		foreach(ref line; f.byLine) {
			if(line.length == 0) {
				continue;
			} else if(line[0] == '-') {
				newEntry = true;
				if(temp.Name.length != 0) {
					this.Functions[temp.Mangled.crc32Of] = temp;
					temp = Function();
				}
			} else if(line[0] == '=') {
				if(temp.Name.length != 0)
					this.Functions[temp.Mangled.crc32Of] = temp;
				auto i = line.indexOfAny("0123456789");
				assert(i > 0);
				auto s = line[i..$].indexOfNeither("0123456789");
				this.TicksPerSecond = line[i..i + s].to!ulong;
				break;
			} else if(line[0] == '\t') {
				auto cap = line.matchFirst(
					regex(r"\t\s*(\d+)\t\s*(\w+)"));
				assert(!cap.empty);
				if(newEntry) {
					temp.calledBy(FunctionElement(
						cap[2].demangle(verbose).dup,
						cap[2].dup,
						cap[1].to!ulong));
				} else {
					temp.callsTo(FunctionElement(
						cap[2].demangle(verbose).dup,
						cap[2].dup,
						cap[1].to!ulong));
				}
			} else {
				auto cap = line.matchFirst(
					regex(r"(\w+)\t\s*-?(\d+)\t\s*-?(\d+)\t\s*-?(\d+)"));
				assert(!cap.empty);
				newEntry = false;
				temp.Name = cap[1].demangle(verbose).dup;
				temp.Mangled = cap[1].dup;
				temp.Calls = cap[2].to!ulong;
				temp.FunctionTime = cap[4].to!ulong;
				temp.Time = cap[3].to!ulong;
			}
		}

		const HASH main = "_Dmain".crc32Of;
		if(main !in this.Functions)
			throw new Exception("Your trace.log is invalid");

		this.TimeOfMain = this.timeOf(main);
	}

	const void toString(scope void delegate(const(char)[]) s, in float threshold = 0) {
		import std.format : format;
		foreach(k, ref v; this.Functions) {
			if(threshold != 0 && this.percOf(k) < threshold)
				continue;
			s("Function '%s':\n".format(v.Name));
			s("\tMangled name: '%s'\n".format(v.Mangled));
			if(v.CallsTo) {
				s("\tCalls:\n");
				foreach(ke, va; v.CallsTo)
					s("\t\t%s\t%d times\n".format(va.Name, va.Calls));
			}
			if(v.CalledBy) {
				s("\tCalled by:\n");
				foreach(ke, va; v.CalledBy)
					s("\t\t%s\t%d times\n".format(va.Name, va.Calls));
			}
			s("\tTook: %f seconds (%f%%)\n"
				.format(this.functionTimeOf(k), this.functionPercOf(k)));
			s("\tFinished in: %f seconds (%f%%)\n"
				.format(this.timeOf(k), this.percOf(k)));
		}
	}

	const void toJSONString(scope void delegate(const(char)[]) s,
		in float threshold = 0,
		in bool pretty = false) {
		if(pretty) {
			s(this.toJSON(threshold).toPrettyString);
			s("\n");
		} else {
			s(this.toJSON(threshold).toString);
		}
	}

	const JSONValue toJSON(in float threshold = 0) {
		JSONValue[] ret;
		foreach(k, ref v; this.Functions) {
			if(threshold != 0 && this.timeOf(k) < threshold)
				continue;

			ret ~= v.toJSON(this.TicksPerSecond);
		}
		return JSONValue([
			"tps" : JSONValue(this.TicksPerSecond),
			"functions" : JSONValue(ret)]);
	}

	@safe pure nothrow const float timeOf(HASH f)
	in {
		assert(f in this.Functions);
	} body {
		return cast(float) this.Functions[f].Time /
			cast(float) this.TicksPerSecond;
	}

	@safe pure nothrow const float percOf(HASH f)
	in {
		assert(f in this.Functions);
	} body {
		return (cast(float) this.Functions[f].Time /
			cast(float) this.TicksPerSecond) / TimeOfMain * 100;
	}

	@safe pure nothrow const float functionTimeOf(HASH f)
	in {
		assert(f in this.Functions);
	} body {
		return cast(float) this.Functions[f].FunctionTime /
			cast(float) this.TicksPerSecond;
	}

	@safe pure nothrow const float functionPercOf(HASH f)
	in {
		assert(f in this.Functions);
	} body {
		return (cast(float) this.Functions[f].FunctionTime /
			cast(float) this.TicksPerSecond) / TimeOfMain * 100;
	}

	const void toDOT(scope void delegate(const(char)[]) s,
			float threshold = 0,
			string[float] colours = [
				0: "limegreen",
				10: "slateblue",
				25: "steelblue",
				50: "royalblue",
				75: "navy",
				95: "red"
			]
		) {
		import std.format : format;
		import std.string : tr, wrap;
		import std.digest.crc : crc32Of;

		string clr(float f) {
			import std.algorithm : sort;
			foreach(k; sort!("a>b")(colours.keys)) {
				if(k <= f) {
					return colours[k];
				}
			}
			return "gray";
		}

		HASH[][HASH] func;
		enum fmt = "\"%s\" [label=\"%s\\n%.2f%%(%.2f%%)\", shape=\"box\"," ~
			" style=filled, fillcolor=\"%s\"];\n";

		foreach(k, ref v; this.Functions) {
			if(threshold == 0 || this.percOf(k) > threshold) {
				func[k] = [];
				foreach(key, unused; v.CallsTo) {
					if(threshold != 0 && this.percOf(key) <= threshold)
						continue;
					if(key !in func)
						func[key] = [];
					func[k] ~= key;
				}
			} else {
				continue;
			}
		}

		s("digraph {\n");
		foreach(k, ref v; func) {
			s(fmt.format(
				this.Functions[k].Mangled.tr("\"", "\\\""),
				this.Functions[k].Name.tr("\"", "\\\"").wrap(40),
				this.percOf(k),
				this.functionPercOf(k),
				clr(this.percOf(k))));
			foreach(i; v) {
				if(i !in func) {
					s(fmt.format(
						this.Functions[i].Mangled.tr("\"", "\\\""),
						this.Functions[i].Name.tr("\"", "\\\"").wrap(40),
						this.percOf(i),
						this.functionPercOf(i),
						clr(this.percOf(i))));
				}
				s("\"%s\" -> \"%s\" [label=\"%dx\"];\n".format(
					this.Functions[k].Mangled.tr("\"", "\\\""),
					this.Functions[i].Mangled.tr("\"", "\\\""),
					this.Functions[k].CallsTo[i].Calls));
			}
		}
		s("}\n");
	}
}

private struct FunctionElement {
	char[] Name;
	char[] Mangled;
	ulong Calls;
}

private struct Function {
	char[] Name;
	char[] Mangled;
	ulong Calls;
	FunctionElement[HASH] CallsTo;
	FunctionElement[HASH] CalledBy;
	ulong FunctionTime;
	ulong Time;

	void callsTo(FunctionElement func) {
		import std.digest.crc : crc32Of;
		HASH h = func.Mangled.crc32Of;
		this.CallsTo[h] = func;
	}

	void calledBy(FunctionElement func) {
		import std.digest.crc : crc32Of;
		HASH h = func.Mangled.crc32Of;
		this.CalledBy[h] = func;
	}

	const JSONValue toJSON(ulong tps = 0) {
		JSONValue ret = JSONValue([
			"name": this.Name,
			"mangled": this.Mangled
		]);
		if(this.CallsTo) {
			JSONValue[] temp;
			foreach(k, v; this.CallsTo) {
				temp ~= JSONValue([
					"name": JSONValue(v.Name),
					"mangled": JSONValue(v.Mangled),
					"calls": JSONValue(v.Calls)
				]);
			}
			ret["callsTo"] = JSONValue(temp);
		}
		if(this.CalledBy) {
			JSONValue[] temp;
			foreach(k, v; this.CalledBy) {
				temp ~= JSONValue([
					"name": JSONValue(v.Name),
					"mangled": JSONValue(v.Mangled),
					"calls": JSONValue(v.Calls)
				]);
			}
			ret["calledBy"] = JSONValue(temp);
		}
		if(tps) {
			ret["functionTimeSec"] = JSONValue(
				cast(float) this.FunctionTime / cast(float) tps);
			ret["timeSec"] = JSONValue(
				cast(float) this.Time / cast(float) tps);
		}
		ret["functionTime"] = JSONValue(this.FunctionTime);
		ret["time"] = JSONValue(this.Time);
		return ret;
	}
}
