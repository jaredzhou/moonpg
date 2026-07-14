// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html

name = "jaredzhou/moonpg"

version = "0.2.0"

readme = "README.mbt.md"

repository = "https://github.com/jaredzhou/moonpg"

license = "Apache-2.0"

keywords = [ "postgres", "postgresql", "wire-protocol", "database" ]

preferred_target = "native"

description = "A pure MoonBit PostgreSQL client, wire protocol from scratch."

import {
  "moonbitlang/async@0.19.0",
  "moonbitlang/x@0.4.46",
  "jaredzhou/libs@0.1.1",
}
