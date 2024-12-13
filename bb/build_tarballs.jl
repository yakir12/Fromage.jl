# Note that this script can accept some limited command-line arguments, run
# `julia build_tarballs.jl --help` to see a usage message.
using BinaryBuilder, Pkg

name = "Exiftool"
version = v"0.0.1"

# Collection of sources required to complete build
sources = [
           GitSource("https://github.com/exiftool/exiftool.git", "393512b71735e477cc20ab5efb494e31f0962db8")
          ]

# if [[ "${target}" == *-w64-mingw32 ]]; then
#     srcext = ""
# fi

# Bash recipe for building across all platforms
script = raw"""
cd $WORKSPACE/srcdir
cd exiftool
perl Makefile.PL
make -j${nproc}
make install
install -Dvm 755 "${WORKSPACE}/srcdir/exiftool/exiftool" "${bindir}/exiftool${exeext}"
cp -r lib ${libdir}/
"""


# These are the platforms we will build for by default, unless further
# platforms are passed in on the command line
platforms = supported_platforms()
# platforms = [Platform("x86_64", "linux")]
# platforms = [Platform("x86_64", "windows")]

# The products that we will ensure are always built
products = Product[ExecutableProduct("exiftool", :exiftool)]

# Dependencies that must be installed before this package can be built
dependencies = Dependency[
                         ]

# Build the tarballs, and possibly a `build.jl` as well.
build_tarballs(ARGS, name, version, sources, script, platforms, products, dependencies; julia_compat="1.6")
