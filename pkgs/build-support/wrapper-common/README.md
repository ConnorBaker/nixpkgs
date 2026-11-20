# Compiler and linker wrapper state

A public compiler invocation selects flags for its active BUILD, HOST and TARGET roles. Role-specific caller variables can change between invocations. The wrapper keeps its selected values in private `wrapper_*` variables so a fresh compiler, including one launched by NVCC, can select its own flags.

A prepared compiler inherits the selected compiler and linker flags. For a linker job, the CC wrapper passes the selected linker policy and records which inputs it has already placed on the driver command line. This preserves link order and prevents duplicate objects. A launcher that runs an independent public linker before continuing the original operation must clear `NIX_WRAPPER_OPERATION` for the independent process.

The CC wrapper scans driver arguments to decide when to add link-only flags. An option operand spelled like a mode switch can affect that decision. For example, use `-o ./-c` when the output filename is `-c` and the job relies on `NIX_CFLAGS_LINK`.

When passing a linker response file through Clang in `NIX_LDFLAGS` or `NIX_LDFLAGS_BEFORE`, use a comma-free outer filename. For example, pass `@link.rsp` and put `@comma,path.rsp` inside it.

On ELF targets the linker wrapper adds store directories containing requested shared libraries to RUNPATH. An input discarded under `--as-needed` can leave its directory first in the search order. Set an explicit `-rpath` when a fresh process would otherwise load the wrong provider, or when a sysroot-relative search needs a deployment path. Search order cannot isolate two plugins that need different libraries with the same SONAME in one loader namespace. The wrapper filters runtime-search options for the selected link mode. Linker scripts, response files and late hooks can still change the result.

The CUDA setup hook registers the backend's dependency collectors without changing the project's C or C++ compiler. Installed NVCC supplies its own executable defaults. The CUDA manual describes how caller library paths reach device links. [CUDA](../../../doc/languages-frameworks/cuda.section.md)
