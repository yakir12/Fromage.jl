# Note that this script can accept some limited command-line arguments, run
# `julia build_tarballs.jl --help` to see a usage message.
using BinaryBuilder, Pkg

name = "Exiftool"
version = v"13.7.0"

# Collection of sources required to complete build
sources = [
           ArchiveSource("https://exiftool.org/Image-ExifTool-13.07.tar.gz", "357f8b4f866bd168ba2eb63b68a7c148dc2859603583657c1a786d26a4327d76")
          ]

# Bash recipe for building across all platforms
script = raw"""
cp $WORKSPACE/srcdir/Image-ExifTool-13.07/exiftool ${bindir}/
cp -r $WORKSPACE/srcdir/Image-ExifTool-13.07/lib ${bindir}/
"""

# These are the platforms we will build for by default, unless further
# platforms are passed in on the command line
platforms = supported_platforms()

# The products that we will ensure are always built
products = Product[FileProduct("exiftool", :exiftool)]

# Dependencies that must be installed before this package can be built
dependencies = Dependency[Dependency("Perl_jll")]

# Build the tarballs, and possibly a `build.jl` as well.
build_tarballs(ARGS, name, version, sources, script, platforms, products, dependencies; julia_compat="1.6")
