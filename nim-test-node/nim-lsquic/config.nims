when not defined(windows):
  # use the C++ linker profile because it's a C++ library
  when defined(macosx):
    switch("clang.linkerexe", "clang++")
  else:
    switch("gcc.linkerexe", "g++")

switch("warningAsError", "UnusedImport:on")
switch("warningAsError", "UseBase:on")

--styleCheck:
  usages
--styleCheck:
  error
