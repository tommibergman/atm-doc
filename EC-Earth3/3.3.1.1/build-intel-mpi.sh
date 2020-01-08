#!/bin/bash

# EC-EARTH3
# =========
#
# puhti.csc.fi, Intel compiler suite
# jukka-pekka.keskinen@helsinki.fi, juha.lento@csc.fi, tommi.bergman@fmi.fi
# 2017-09-03, 2017-09-21, 2019-02-27, 2019-08-30, 2019-12-19

usage="
Usage: bash $0

         or

       source $0

The first invocation tries to build everything with one go, the second
one just loads variables and functions to the current shell, and one
can run the functions one by one (debug).

Requires that the following files are in the same directory with this
script

    config-build.xml
    csc-puhti-intel.xml
    puhti.cfg.tmpl
    puhti.xml

It may look like the script is doing nothing, if it works :) That's
because the output of the build functions is redirected to files
in ${BLDROOT}/${TAG}/*.log. Just open another terminal and monitor the
log files. Something like

    ls -ltr ${BLDROOT}/${TAG}/*.log

"


### Local/user defaults ###

: ${TAG:=3.3.1.1}
: ${BLDROOT:=/fmi/projappl/project_2001927/$USER/ece3}
: ${INSTALLROOT:=/fmi/projappl/project_2001927/$USER/ece3}
: ${RUNROOT:=/fmi/scratch/project_2001927/$USER/ece3}
: ${PLATFORM:=csc-puhti-intel-intelmpi}
: ${GRIBEX_TAR_GZ:=${HOME}/gribex_000370.tar.gz}
# : ${REVNO:=6611}

setbldroot () {
BLDROOT=`pwd`
echo $BLDROOT
}
### Some general bash scripting stuff ###

# Check if this script is sourced or run interactively

[[ "$0" != "${BASH_SOURCE}" ]] && sourced=true || sourced=false
${sourced} || set -e

# The directory of this script and auxiliary files

thisdir=$(readlink -f $(dirname $BASH_SOURCE))


### Environment setup ###

module purge
module load intel/18.0.5
module load intel-mpi/18.0.5     
module load intel-mkl/2018.0.5
module load hdf/4.2.13
module load hdf5/1.10.4-mpi
module load netcdf/4.7.0
module load netcdf-fortran/4.4.4
module load grib-api/1.24.0
module load cmake/3.12.3

### Helper functions ###

expand-variables () {
    local infile="$1"
    local outfile="$2"
    local tmpfile="$(mktemp)"
    eval 'echo "'"$(sed 's/\\/\\\\/g;s/\"/\\\"/g' $infile)"'"' > "$tmpfile"
    if ! diff -s "$outfile" "$tmpfile" &> /dev/null; then
	VERSION_CONTROL=t \cp -f --backup "$tmpfile" "$outfile"
    fi
}


### EC-EARTH3 related functions ###


updatesources () {
    [ "$REVNO" ] && local revflag="-r $REVNO"
    mkdir -p $BLDROOT
    cd $BLDROOT
    svn checkout https://svn.ec-earth.org/ecearth3/tags/$TAG $TAG
    svn checkout https://svn.ec-earth.org/vendor/gribex/gribex_000370 gribex_000370

}

ecconfig () {
    cd ${BLDROOT}//sources
    ./util/ec-conf/ec-conf --platform=${PLATFORM} ./config-build.xml
}

oasis () {
    cd ${BLDROOT}//sources/oasis3-mct/util/make_dir
    FCLIBS=" " make -f TopMakefileOasis3 BUILD_ARCH=ecconf realclean
    FCLIBS=" " make -f TopMakefileOasis3 BUILD_ARCH=ecconf
}

lucia() {
    cd ${BLDROOT}//sources/oasis3-mct/util/lucia
    bash lucia -c
}

xios () {
    cd ${BLDROOT}//sources/xios-2.5
    ./make_xios --dev --arch ecconf --use_oasis oasis3_mct --netcdf_lib netcdf4_par --job 4 --full
}

nemo () {
    cd ${BLDROOT}//sources/nemo-3.6/CONFIG
    ./makenemo clean
    ./makenemo -n ORCA1L75_LIM3 -m ecconf -j 4
    ./makenemo -n ORCA1L75_LIM3_CarbonCycle -m ecconf -j 4
}

oifs () {
    # gribex first
    cd ${BLDROOT}/gribex_000370
    ./build_library <<EOF
i
y
${BLDROOT}//sources/ifs-36r4/lib
n
EOF
    mv libgribexR64.a ${BLDROOT}//sources/ifs-36r4/lib

    # ifs
    cd ${BLDROOT}//sources/ifs-36r4
    #sed -i '666s/STATUS=IRET/IRET/' src/ifsaux/module/grib_api_interface.F90
    make BUILD_ARCH=ecconf realclean
    make BUILD_ARCH=ecconf dep-clean

    make BUILD_ARCH=ecconf -j 8 lib
    make BUILD_ARCH=ecconf master
}


tm5 () {
    cd ${BLDROOT}//sources/tm5mp
    # patch -u -p0 < $thisdir/tm5.patch
    #sed -i 's/\?//g' base/convection.F90
    PATH=${BLDROOT}//sources/util/makedepf90/bin:$PATH ./setup_tm5 -n -j 4 ecconfig-ecearth3.rc

}

runoff-mapper () {
    cd ${BLDROOT}//sources/runoff-mapper/src
    make clean
    make
}

amip-forcing () {
    cd ${BLDROOT}//sources/amip-forcing/src
    make clean
    make
}

lpj-guess () {
    cd ${BLDROOT}//sources/lpjg/build
    make clean
    cmake .. -DCMAKE_Fortran_FLAGS="-I${INTEL_MPI_INSTALL_ROOT}/lib"
    make # Fails with int <---> MPI_Comm type errors...
}

# Install
install_all () {
    mkdir -p ${INSTALLROOT}//${REVNO}
    local exes=(
	      xios-2.5/bin/xios_server.exe
	      nemo-3.6/CONFIG/ORCA1L75_LIM3/BLD/bin/nemo.exe
	      ifs-36r4/bin/ifsmaster-ecconf
	      runoff-mapper/bin/runoff-mapper.exe
	      amip-forcing/bin/amip-forcing.exe
	      tm5mp/build/appl-tm5.x
	      oasis3-mct/util/lucia/lucia.exe
	      oasis3-mct/util/lucia/lucia
	      oasis3-mct/util/lucia/balance.gnu)
	  for exe in "${exes[@]}"; do
        cp -f ${BLDROOT}//sources/${exe} ${INSTALLROOT}//${REVNO}/
    done
    cp -f /appl/climate/bin/cdo ${INSTALLROOT}//${REVNO}/
}

# Create run directory and fix stuff

create_ece_run () {
    cd $RUNROOT
    mkdir -p ece--r${REVNO}
    \cp -r ${BLDROOT}//runtime/* ${RUNROOT}/ece--r${REVNO}/
    \cp ./${PLATFORM}.cfg.tmpl ${RUNROOT}/ece--r${REVNO}/classic/platform/
    \cp ./${PLATFORM}.xml ${RUNROOT}/ece--r${REVNO}/classic/platform/
    cd ${RUNROOT}/ece--r${REVNO}
    \cp classic/ece-esm.sh.tmpl classic/ece-ifs+nemo+tm5.sh.tmpl
    sed "s|THIS_NEEDS_TO_BE_CHANGED|${INSTALLROOT}//${REVNO}|" ./rundir.patch | patch -u -p0
    mkdir -p ${RUNROOT}/ece--r${REVNO}/tm5mp
    cd ${RUNROOT}/ece--r${REVNO}/tm5mp
    \cp -r ${BLDROOT}//sources/tm5mp/rc .
    \cp -r ${BLDROOT}//sources/tm5mp/bin .
    \cp -r ${BLDROOT}//sources/tm5mp/build .
    ln -s bin/pycasso_setup_tm5 setup_tm5
}

compile_all () {
    #ecconfig
    #echo "Building all components in "
    #echo ${BLDROOT}
    #echo " running ecconf"
    ( ecconfig       2>&1 ) > ${BLDROOT}//ecconf.log
    #echo "compiling oasis"
    ( oasis          2>&1 ) > ${BLDROOT}//oasis.log    &
    wait
    echo " compiling lucia"
    ( lucia          2>&1 ) > ${BLDROOT}//lucia.log    &
    echo "compiling xios"
    ( xios           2>&1 ) > ${BLDROOT}//xios.log &
    echo "compiling tm5"
    ( tm5            2>&1 ) > ${BLDROOT}//tm5.log  &
    echo "compiling lpj-guess"
    ( lpj-guess      2>&1 ) > ${BLDROOT}//lpjg.log  &
    wait
    echo " compiling ifs, nemo, runoff mapper"
    ( oifs           2>&1 ) > ${BLDROOT}//ifs.log &
    echo "compiling nemo"
    ( nemo           2>&1 ) > ${BLDROOT}//nemo.log &
    echo "compiling runoff-mapper"
    ( runoff-mapper  2>&1 ) > ${BLDROOT}//runoff.log &
    echo " compiling amip-forcing"
    ( amip-forcing   2>&1 ) > ${BLDROOT}//amipf.log &
    wait
}

### Execute all functions if this script is not sourced ###

if ! ${sourced}; then
    updatesources
    ( module -t list 2>&1 ) > ${BLDROOT}//modules.log
    ( ecconfig       2>&1 ) > ${BLDROOT}//ecconf.log
    ( oasis          2>&1 ) > ${BLDROOT}//oasis.log    &
    wait
    ( lucia          2>&1 ) > ${BLDROOT}//lucia.log    &
    ( xios           2>&1 ) > ${BLDROOT}//xios.log &
    ( tm5            2>&1 ) > ${BLDROOT}//tm5.log  &
    wait
    ( oifs           2>&1 ) > ${BLDROOT}//ifs.log &
    ( nemo           2>&1 ) > ${BLDROOT}//nemo.log &
    ( runoff-mapper  2>&1 ) > ${BLDROOT}//runoff.log &
    wait
    ( amip-forcing   2>&1 ) > ${BLDROOT}//amipf.log &
    wait
    install_all
    create_ece_run
fi
