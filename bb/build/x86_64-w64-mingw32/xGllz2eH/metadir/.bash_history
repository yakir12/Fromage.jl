cd $WORKSPACE/srcdir
cd exiftool
perl Makefile.PL
make -j${nproc}
make install
install -Dvm 755 "${WORKSPACE}/srcdir/exiftool/exiftool${exeext}" "${bindir}/exiftool${exeext}"
install -Dvm 755 "${WORKSPACE}/srcdir/exiftool/exiftool${exeext}" "${bindir}/exiftool${exeext}"
install -Dvm 755 "${WORKSPACE}/srcdir/exiftool/exiftool${exeext}" "${bindir}/exiftool${exeext}"
