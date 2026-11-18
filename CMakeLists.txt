cmake_minimum_required(VERSION 3.25)

project(
    openssl-cmake
    VERSION 4.1.0
    DESCRIPTION "Build OpenSSL in parallel within CMake"
    HOMEPAGE_URL "https://github.com/jimmy-park/openssl-cmake"
    LANGUAGES C
)

###############
# ASI default settings
list(APPEND CMAKE_MODULE_PATH "$ENV{ASV_CMAKE}")
include(asv_cmake_defaults)
asv_cmake_defaults( )
###############

# ASI default
option(BUILD_SHARED_LIBS "Enable shared library" ON)

if(NOT PROJECT_IS_TOP_LEVEL)
    list(APPEND CMAKE_MESSAGE_INDENT "[${PROJECT_NAME}] ")
endif()

set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE NEVER)

include(FetchContent)
include(ProcessorCount)
include(cmake/CheckBuildMismatches.cmake)
include(cmake/ConfigureOpenSSL.cmake)
include(cmake/DetectTargetPlatform.cmake)
include(cmake/FetchOpenSSL.cmake)
include(cmake/FindVcvarsall.cmake)

# Custom options
set(OPENSSL_TARGET_VERSION 3.5.8 CACHE STRING "OpenSSL release to build")
option(OPENSSL_BUILD_VERBOSE "Enable verbose output from build" OFF)
option(OPENSSL_CONFIGURE_VERBOSE "Enable verbose output from configuration" OFF)
option(OPENSSL_ENABLE_PARALLEL "Build and test in parallel if possible" ON)
option(OPENSSL_INSTALL "Install OpenSSL components to the <prefix> directory" ON)
option(OPENSSL_INSTALL_CERT "Install cert.pem to the <openssldir> directory" OFF)
option(OPENSSL_TEST "Enable testing and build OpenSSL self tests" OFF)
option(OPENSSL_USE_CCACHE "Use ccache if available" ON)

if("${OPENSSL_BUILD_TARGET}" STREQUAL "")
    # Makefile target for build
    set(OPENSSL_BUILD_TARGET build_libs)
endif()

if("${OPENSSL_INSTALL_TARGET}" STREQUAL "")
    # Makefile target for install
    set(OPENSSL_INSTALL_TARGET install_dev)
endif()

if("${OPENSSL_TARGET_PLATFORM}" STREQUAL "")
    # Use OpenSSL's Configure target
    detect_target_platform(OPENSSL_TARGET_PLATFORM)
endif()

message(STATUS "Preparing OpenSSL build")
message(STATUS "Target platform: ${OPENSSL_TARGET_PLATFORM}")

# Fetch OpenSSL source
fetch_openssl()

# Apply patches
foreach(patch IN LISTS OPENSSL_PATCH)
    if(EXISTS "${patch}" AND NOT IS_DIRECTORY "${patch}")
        if(NOT IS_ABSOLUTE "${patch}")
            string(PREPEND patch ${CMAKE_SOURCE_DIR}/)
        endif()

        execute_process(
            COMMAND git init
            WORKING_DIRECTORY ${openssl_SOURCE_DIR}
            OUTPUT_QUIET
            ERROR_QUIET
        )
        execute_process(
            COMMAND git apply ${patch}
            WORKING_DIRECTORY ${openssl_SOURCE_DIR}
            OUTPUT_QUIET
            ERROR_QUIET
        )
    endif()
endforeach()

# ASI winx: clang-cl cross build of OpenSSL for Windows x64, hosted on Linux.
# The target is MSVC ABI, but there is no vcvarsall, nmake or MSWin32 perl here:
# GNU make drives unix-Makefile.tmpl and the winx toolchain supplies the llvm tools.
set(ASV_WINX OFF)

if(MSVC AND CMAKE_CROSSCOMPILING AND CMAKE_HOST_UNIX)
    set(ASV_WINX ON)
endif()

# ASI winx: apply the clang-cl/unix-Makefile patch to the source once. A reverse
# dry run that succeeds means the patch is already in the tree.
if(ASV_WINX)
    find_program(OPENSSL_PATCH_TOOL patch REQUIRED)
    set(ASV_WINX_PATCH ${CMAKE_CURRENT_SOURCE_DIR}/patches/openssl-winx-clang-cl.patch)

    execute_process(
        COMMAND ${OPENSSL_PATCH_TOOL} -p1 -R --dry-run -s -f -i ${ASV_WINX_PATCH}
        WORKING_DIRECTORY ${openssl_SOURCE_DIR}
        RESULT_VARIABLE ASV_WINX_PATCH_REVERSE_RC
        OUTPUT_QUIET
        ERROR_QUIET
    )

    if(ASV_WINX_PATCH_REVERSE_RC EQUAL 0)
        message(STATUS "winx OpenSSL patch already applied")
    else()
        execute_process(
            COMMAND ${OPENSSL_PATCH_TOOL} -p1 -N -f -i ${ASV_WINX_PATCH}
            WORKING_DIRECTORY ${openssl_SOURCE_DIR}
            RESULT_VARIABLE ASV_WINX_PATCH_RC
        )

        if(NOT ASV_WINX_PATCH_RC EQUAL 0)
            message(FATAL_ERROR
                "Failed to apply the winx OpenSSL patch.\n"
                "  patch file: ${ASV_WINX_PATCH}\n"
                "  source dir: ${openssl_SOURCE_DIR}"
            )
        endif()
    endif()
endif()

# Run vcvarsall.bat with target architecture
# ASI: skip it when a VS developer environment is already set (setup-env sets
# VSCMD_VER, INCLUDE, LIB and cl on PATH); VsDevCmd.bat fails when re-run on top.
# ASI winx: there is no vcvarsall to run.
if(ASV_WINX)
    set(VCVARSALL_COMMAND "")
elseif(DEFINED ENV{VSCMD_VER})
    set(VCVARSALL_COMMAND "")
else()
    set_vcvarsall_command(VCVARSALL_COMMAND)
endif()

# Set environment variables for Android NDK
if(ANDROID)
    set(ENV{PATH} ${ANDROID_TOOLCHAIN_ROOT}/bin:$ENV{PATH})
    set(ENV{ANDROID_NDK_ROOT} ${CMAKE_ANDROID_NDK})
endif()

# Set the number of threads
if(OPENSSL_ENABLE_PARALLEL)
    ProcessorCount(NUMBER_OF_THREADS)

    if(NUMBER_OF_THREADS EQUAL 0)
        set(NUMBER_OF_THREADS 1)
    endif()
else()
    set(NUMBER_OF_THREADS 1)
endif()

# Find build tool
# ASI winx: GNU make (the else branch below), not nmake or jom
if(MSVC AND NOT ASV_WINX)
    if(NUMBER_OF_THREADS GREATER 1)
        find_program(JOM jom)

        if(JOM)
            set(OPENSSL_BUILD_TOOL ${JOM})
        else()
            set(NUMBER_OF_THREADS 1)
        endif()
    endif()

    if(NUMBER_OF_THREADS EQUAL 1)
        cmake_path(GET CMAKE_C_COMPILER PARENT_PATH NMAKE_PATH)
        find_program(
            NMAKE
            NAMES nmake
            PATHS ${NMAKE_PATH}
            REQUIRED
            NO_DEFAULT_PATH
        )
        set(OPENSSL_BUILD_TOOL ${NMAKE})
    endif()
elseif(MINGW)
    find_program(MAKE mingw32-make REQUIRED)
    set(OPENSSL_BUILD_TOOL ${MAKE})
else()
    find_program(MAKE NAMES gmake make REQUIRED)
    execute_process(COMMAND ${MAKE} --version OUTPUT_VARIABLE MAKE_VERSION_OUTPUT)
    set(OPENSSL_BUILD_TOOL ${MAKE})
endif()

cmake_path(GET OPENSSL_BUILD_TOOL FILENAME OPENSSL_BUILD_TOOL_NAME)
message(STATUS "Build tool: ${OPENSSL_BUILD_TOOL_NAME}")
message(VERBOSE "Build tool path: ${OPENSSL_BUILD_TOOL}")
message(STATUS "Parallel jobs: ${NUMBER_OF_THREADS}")

# Modify configure/build options
if(OPENSSL_TEST AND NOT CMAKE_CROSSCOMPILING)
    set(OPENSSL_BUILD_TARGET "")
else()
    list(APPEND OPENSSL_CONFIGURE_OPTIONS no-tests)
endif()

if(NOT OPENSSL_BUILD_VERBOSE)
    if(MSVC AND NOT ASV_WINX)
        list(APPEND OPENSSL_BUILD_OPTIONS /NOLOGO /S)

        # LNK4099 : PDB 'filename' was not found with 'object/library' or at 'path'
        set(ENV{LDFLAGS} "/NOLOGO /DEBUG /IGNORE:4099")
    else()
        list(APPEND OPENSSL_BUILD_OPTIONS -s)
    endif()
endif()

if(NUMBER_OF_THREADS GREATER 1)
    if(MSVC AND NOT ASV_WINX)
        list(APPEND OPENSSL_CONFIGURE_OPTIONS /FS)
        list(APPEND OPENSSL_BUILD_OPTIONS /J ${NUMBER_OF_THREADS})
    elseif(MAKE_VERSION_OUTPUT MATCHES "GNU")
        # Only append job subprocess arg if its gnu make, other makes DO NOT BEHAVE WELL!
        list(APPEND OPENSSL_BUILD_OPTIONS -j ${NUMBER_OF_THREADS})
    endif()
endif()

if(NOT BUILD_SHARED_LIBS)
    list(APPEND OPENSSL_CONFIGURE_OPTIONS no-shared)
endif()

# ASI defaults: install into the CMake prefix (the ports tree) with libs in lib/,
# not OpenSSL's /usr/local or C:/Program Files default and linux-x86_64's lib64/.
# The openssldir (openssl.cnf, default CA store) is ssl/ inside the port too - a
# relative --openssldir is taken relative to --prefix - never a host directory.
cmake_path(NATIVE_PATH CMAKE_INSTALL_PREFIX OPENSSL_INSTALL_PREFIX)
list(APPEND OPENSSL_CONFIGURE_OPTIONS --prefix=${OPENSSL_INSTALL_PREFIX} --libdir=lib --openssldir=ssl)

# ASI Windows defaults:
# - Configure needs a native Windows perl ($^O MSWin32, e.g. Strawberry Perl); OpenSSL
#   rejects msys2 perl for MSVC builds, and msys2 perl is earlier on PATH. Take the
#   first perl on PATH that is native.
# - no-asm: the x64 assembly needs NASM; plain C is fast enough for database TLS.
# ASI winx: the Linux host perl runs Configure, so the MSWin32 validator is skipped;
# no-makedepend because there is no makedepend tool for the clang-cl target.
if(WIN32)
    if(ASV_WINX)
        find_program(OPENSSL_CONFIGURE_TOOL perl REQUIRED)
        list(APPEND OPENSSL_CONFIGURE_OPTIONS no-makedepend)
    else()
        function(asv_native_windows_perl result candidate)
            execute_process(
                COMMAND "${candidate}" -e "print $^O"
                OUTPUT_VARIABLE perl_os
                RESULT_VARIABLE perl_rc
            )
            if(NOT perl_rc EQUAL 0 OR NOT perl_os STREQUAL "MSWin32")
                set(${result} FALSE PARENT_SCOPE)
            endif()
        endfunction()
        find_program(OPENSSL_CONFIGURE_TOOL perl
            VALIDATOR asv_native_windows_perl
            REQUIRED
        )
    endif()
    list(APPEND OPENSSL_CONFIGURE_OPTIONS no-asm)
endif()

# ASI: build the "-asv" shared-library variant (OpenSSL's shlib_variant):
# libssl-asv.so.3 / libcrypto-asv.so.3 (libssl-3-asv-x64.dll on Windows) with
# OPENSSL_ASV_* symbol versions. It never shadows the system or another
# OpenSSL of the stock names (Debian libssl3, msys2, EDB), and coexists in one
# process with the libssl.so.3 that libpq and msodbcsql load.
set(OPENSSL_ASV_TARGET asv-${OPENSSL_TARGET_PLATFORM})
set(OPENSSL_ASV_CONFIG ${CMAKE_CURRENT_BINARY_DIR}/asv-variant.conf)

if(ASV_WINX)
    # ASI winx: the full clang-cl target. The llvm tools come from their CMake
    # variables when set, else from the directory of CMAKE_C_COMPILER.
    cmake_path(GET CMAKE_C_COMPILER PARENT_PATH ASV_WINX_LLVM_BIN)

    if(CMAKE_LINKER)
        set(ASV_WINX_LD ${CMAKE_LINKER})
    else()
        set(ASV_WINX_LD ${ASV_WINX_LLVM_BIN}/lld-link)
    endif()

    if(CMAKE_AR)
        set(ASV_WINX_AR ${CMAKE_AR})
    else()
        set(ASV_WINX_AR ${ASV_WINX_LLVM_BIN}/llvm-lib)
    endif()

    if(CMAKE_RC_COMPILER)
        set(ASV_WINX_RC ${CMAKE_RC_COMPILER})
    else()
        set(ASV_WINX_RC ${ASV_WINX_LLVM_BIN}/llvm-rc)
    endif()

    # The flags land in Makefile variables that make hands to the shell, so
    # the sysroot is single-quoted: WIN_CROSS_SYSROOT may contain spaces.
    file(WRITE ${OPENSSL_ASV_CONFIG}
        "## ASI: WinGLUE OpenSSL variant, generated by ssl-jp CMakeLists.txt (winx clang-cl target)\n"
        "my %targets = (\n"
        "    \"${OPENSSL_ASV_TARGET}\" => {\n"
        "        inherit_from     => [ \"VC-WIN64-common\" ],\n"
        "        build_scheme     => [ \"unified\", \"unix\" ],\n"
        "        build_file       => \"Makefile\",\n"
        "        CC               => \"${CMAKE_C_COMPILER}\",\n"
        "        CPP              => \"${CMAKE_C_COMPILER} /EP /C\",\n"
        "        CFLAGS           => \"'/winsysroot${WIN_CROSS_SYSROOT}' --target=x86_64-pc-windows-msvc /nologo /W3 /wd4090 -Wno-everything /O2\",\n"
        "        cflags           => \"/MD /Gs0 /GF /Gy\",\n"
        "        lib_cflags       => \"\",\n"
        "        dso_cflags       => \"\",\n"
        "        bin_cflags       => \"\",\n"
        "        coutflag         => \"-o \",\n"
        "        makedep_scheme   => \"none\",\n"
        "        makedepcmd       => undef,\n"
        "        LD               => \"${ASV_WINX_LD}\",\n"
        "        LDFLAGS          => \"/nologo '/winsysroot:${WIN_CROSS_SYSROOT}' /machine:x64\",\n"
        "        bin_lflags       => \"/subsystem:console /opt:ref\",\n"
        "        shared_ldflag    => \"/dll\",\n"
        "        shared_target    => \"windows-shared\",\n"
        "        shared_defflag   => \"/def:\",\n"
        "        AR               => \"${ASV_WINX_AR}\",\n"
        "        ARFLAGS          => \"/nologo\",\n"
        "        aroutflag        => \"/OUT:\",\n"
        "        RC               => \"${ASV_WINX_RC}\",\n"
        "        RANLIB           => undef,\n"
        "        AS               => \"${CMAKE_C_COMPILER}\",\n"
        "        sys_id           => \"WIN64A\",\n"
        "        uplink_arch      => undef,\n"
        "        asm_arch         => 'x86_64',\n"
        "        perlasm_scheme   => \"nasm\",\n"
        "        multilib         => \"-x64\",\n"
        "        shlib_variant    => \"-asv\",\n"
        "        ex_libs          => \"ws2_32.lib gdi32.lib advapi32.lib crypt32.lib user32.lib\",\n"
        "        perl_platform    => 'Windows::MSVC',\n"
        "    },\n"
        ");\n"
    )
else()
    # ASI: plain inherit-only variant for every other platform (unchanged)
    file(WRITE ${OPENSSL_ASV_CONFIG}
        "## ASI: WinGLUE OpenSSL variant, generated by ssl-jp CMakeLists.txt\n"
        "my %targets = (\n"
        "    \"${OPENSSL_ASV_TARGET}\" => {\n"
        "        inherit_from => [ \"${OPENSSL_TARGET_PLATFORM}\" ],\n"
        "        shlib_variant => \"-asv\",\n"
        "    },\n"
        ");\n"
    )
endif()

list(APPEND OPENSSL_CONFIGURE_OPTIONS --config=${OPENSSL_ASV_CONFIG})

list(SORT OPENSSL_CONFIGURE_OPTIONS)
list(REMOVE_DUPLICATES OPENSSL_CONFIGURE_OPTIONS)
list(PREPEND OPENSSL_CONFIGURE_OPTIONS ${OPENSSL_ASV_TARGET})

# Configure OpenSSL
configure_openssl(
    COMMAND ${VCVARSALL_COMMAND}
    FILE ${openssl_SOURCE_DIR}/Configure
    BUILD_DIR ${openssl_BINARY_DIR}
    OPTIONS ${OPENSSL_CONFIGURE_OPTIONS}
)

# Parse configdata.pm
parse_configdata("options" OPENSSL_CONFIGURED_OPTIONS)
parse_configdata("version" OPENSSL_CONFIGURED_VERSION)

if("no-shared" IN_LIST OPENSSL_CONFIGURED_OPTIONS)
    set(OPENSSL_BUILD_SHARED_LIBS OFF)
    set(OPENSSL_LIBRARY_TYPE STATIC)
else()
    set(OPENSSL_BUILD_SHARED_LIBS ON)
    set(OPENSSL_LIBRARY_TYPE SHARED)
endif()

message(VERBOSE "Resolved library type: ${OPENSSL_LIBRARY_TYPE}")
check_build_mismatches()

# Parse Makefile
parse_makefile(${OPENSSL_MAKEFILE} "INSTALL_LIBS" OPENSSL_STATIC_LIBS)
parse_makefile(${OPENSSL_MAKEFILE} "INSTALL_SHLIBS" OPENSSL_SHARED_LIBS)
list(TRANSFORM OPENSSL_STATIC_LIBS PREPEND "${openssl_BINARY_DIR}/")
list(TRANSFORM OPENSSL_SHARED_LIBS PREPEND "${openssl_BINARY_DIR}/")

foreach(LIBRARY IN LISTS OPENSSL_STATIC_LIBS)
    if(LIBRARY MATCHES "crypto")
        set(OPENSSL_STATIC_CRYPTO_LIBRARY ${LIBRARY})
    elseif(LIBRARY MATCHES "ssl")
        set(OPENSSL_STATIC_SSL_LIBRARY ${LIBRARY})
    endif()
endforeach()

foreach(LIBRARY IN LISTS OPENSSL_SHARED_LIBS)
    if(LIBRARY MATCHES "crypto")
        set(OPENSSL_SHARED_CRYPTO_LIBRARY ${LIBRARY})
    elseif(LIBRARY MATCHES "ssl")
        set(OPENSSL_SHARED_SSL_LIBRARY ${LIBRARY})
    endif()
endforeach()

if(NOT OPENSSL_BUILD_SHARED_LIBS)
    if(WIN32)
        list(APPEND OPENSSL_LINK_DEPENDENCIES ws2_32 crypt32)
    elseif(LINUX)
        find_package(Threads)

        if(Threads_FOUND)
            list(APPEND OPENSSL_LINK_DEPENDENCIES Threads::Threads)
            list(APPEND OPENSSL_DEPENDENCIES ${CMAKE_THREAD_LIBS_INIT})
        endif()

        list(APPEND OPENSSL_LINK_DEPENDENCIES ${CMAKE_DL_LIBS})
    endif()
endif()

# Provide same targets and variables as FindOpenSSL module
set(OPENSSL_FOUND ON CACHE BOOL "Override FindOpenSSL variables" FORCE)
set(OPENSSL_INCLUDE_DIR ${openssl_SOURCE_DIR}/include ${openssl_BINARY_DIR}/include CACHE STRING "Override FindOpenSSL variables" FORCE)
set(OPENSSL_CRYPTO_LIBRARY ${OPENSSL_${OPENSSL_LIBRARY_TYPE}_CRYPTO_LIBRARY} CACHE STRING "Override FindOpenSSL variables" FORCE)
set(OPENSSL_CRYPTO_LIBRARIES ${OPENSSL_CRYPTO_LIBRARY} ${OPENSSL_DEPENDENCIES} CACHE STRING "Override FindOpenSSL variables" FORCE)
set(OPENSSL_SSL_LIBRARY ${OPENSSL_${OPENSSL_LIBRARY_TYPE}_SSL_LIBRARY} CACHE STRING "Override FindOpenSSL variables" FORCE)
set(OPENSSL_SSL_LIBRARIES ${OPENSSL_SSL_LIBRARY} ${OPENSSL_DEPENDENCIES} CACHE STRING "Override FindOpenSSL variables" FORCE)
set(OPENSSL_LIBRARIES ${OPENSSL_CRYPTO_LIBRARY} ${OPENSSL_SSL_LIBRARY} ${OPENSSL_DEPENDENCIES} CACHE STRING "Override FindOpenSSL variables" FORCE)
set(OPENSSL_VERSION ${OPENSSL_CONFIGURED_VERSION} CACHE STRING "Override FindOpenSSL variables" FORCE)
set(OPENSSL_APPLINK_SOURCE ${openssl_SOURCE_DIR}/ms/applink.c CACHE STRING "Override FindOpenSSL variables" FORCE)

add_library(OpenSSL::Crypto ${OPENSSL_LIBRARY_TYPE} IMPORTED GLOBAL)
add_library(OpenSSL::SSL ${OPENSSL_LIBRARY_TYPE} IMPORTED GLOBAL)
add_library(OpenSSL::applink INTERFACE IMPORTED GLOBAL)

set_target_properties(OpenSSL::Crypto PROPERTIES
    IMPORTED_LINK_INTERFACE_LANGUAGES C
    IMPORTED_LOCATION "${OPENSSL_CRYPTO_LIBRARY}"
    INTERFACE_INCLUDE_DIRECTORIES "${OPENSSL_INCLUDE_DIR}"
    INTERFACE_LINK_LIBRARIES "${OPENSSL_LINK_DEPENDENCIES}"
)
set_target_properties(OpenSSL::SSL PROPERTIES
    IMPORTED_LINK_INTERFACE_LANGUAGES C
    IMPORTED_LOCATION "${OPENSSL_SSL_LIBRARY}"
    INTERFACE_INCLUDE_DIRECTORIES "${OPENSSL_INCLUDE_DIR}"
    INTERFACE_LINK_LIBRARIES "${OPENSSL_LINK_DEPENDENCIES};OpenSSL::Crypto"
)

if(MSVC AND OPENSSL_BUILD_SHARED_LIBS)
    set_target_properties(OpenSSL::Crypto PROPERTIES
        IMPORTED_IMPLIB ${OPENSSL_STATIC_CRYPTO_LIBRARY}
    )
    set_target_properties(OpenSSL::SSL PROPERTIES
        IMPORTED_IMPLIB ${OPENSSL_STATIC_SSL_LIBRARY}
    )
    set_target_properties(OpenSSL::applink PROPERTIES
        INTERFACE_SOURCES ${OPENSSL_APPLINK_SOURCE}
    )

    # Overwrite cache
    set(OPENSSL_CRYPTO_LIBRARY ${OPENSSL_STATIC_CRYPTO_LIBRARY} CACHE STRING "Override FindOpenSSL variables" FORCE)
    set(OPENSSL_CRYPTO_LIBRARIES ${OPENSSL_CRYPTO_LIBRARY} ${OPENSSL_DEPENDENCIES} CACHE STRING "Override FindOpenSSL variables" FORCE)
    set(OPENSSL_SSL_LIBRARY ${OPENSSL_STATIC_SSL_LIBRARY} CACHE STRING "Override FindOpenSSL variables" FORCE)
    set(OPENSSL_SSL_LIBRARIES ${OPENSSL_SSL_LIBRARY} ${OPENSSL_DEPENDENCIES} CACHE STRING "Override FindOpenSSL variables" FORCE)
    set(OPENSSL_LIBRARIES ${OPENSSL_CRYPTO_LIBRARY} ${OPENSSL_SSL_LIBRARY} ${OPENSSL_DEPENDENCIES} CACHE STRING "Override FindOpenSSL variables" FORCE)
endif()

message(VERBOSE "Resolved OpenSSL variables")
list(APPEND CMAKE_MESSAGE_INDENT "  ")
message(VERBOSE "OPENSSL_FOUND            : ${OPENSSL_FOUND}")
message(VERBOSE "OPENSSL_INCLUDE_DIR      : ${OPENSSL_INCLUDE_DIR}")
message(VERBOSE "OPENSSL_CRYPTO_LIBRARY   : ${OPENSSL_CRYPTO_LIBRARY}")
message(VERBOSE "OPENSSL_CRYPTO_LIBRARIES : ${OPENSSL_CRYPTO_LIBRARIES}")
message(VERBOSE "OPENSSL_SSL_LIBRARY      : ${OPENSSL_SSL_LIBRARY}")
message(VERBOSE "OPENSSL_SSL_LIBRARIES    : ${OPENSSL_SSL_LIBRARIES}")
message(VERBOSE "OPENSSL_LIBRARIES        : ${OPENSSL_LIBRARIES}")
message(VERBOSE "OPENSSL_VERSION          : ${OPENSSL_VERSION}")
message(VERBOSE "OPENSSL_APPLINK_SOURCE   : ${OPENSSL_APPLINK_SOURCE}")
list(POP_BACK CMAKE_MESSAGE_INDENT)

# Add a custom target to build OpenSSL
set(OPENSSL_BUILD_COMMAND
    ${VCVARSALL_COMMAND} ${OPENSSL_BUILD_TOOL} ${OPENSSL_BUILD_OPTIONS} ${OPENSSL_BUILD_TARGET}
)

if(ANDROID)
    list(PREPEND OPENSSL_BUILD_COMMAND
        ${CMAKE_COMMAND} -E env PATH=$ENV{PATH} --
    )
endif()

file(GLOB_RECURSE OPENSSL_SOURCES
    ${openssl_SOURCE_DIR}/*.[ch]
    ${openssl_SOURCE_DIR}/*.[ch].in
)

set(OPENSSL_BUILD_OUTPUT
    ${OPENSSL_STATIC_CRYPTO_LIBRARY}
    ${OPENSSL_STATIC_SSL_LIBRARY}
    ${OPENSSL_SHARED_CRYPTO_LIBRARY}
    ${OPENSSL_SHARED_SSL_LIBRARY}
)
add_custom_command(
    OUTPUT ${OPENSSL_BUILD_OUTPUT}
    COMMAND ${OPENSSL_BUILD_COMMAND}
    DEPENDS ${OPENSSL_SOURCES} ${openssl_BINARY_DIR}/configdata.pm
    WORKING_DIRECTORY ${openssl_BINARY_DIR}
    VERBATIM
)

if(PROJECT_IS_TOP_LEVEL)
    add_custom_target(openssl-build ALL DEPENDS ${OPENSSL_BUILD_OUTPUT})
else()
    add_custom_target(openssl-build DEPENDS ${OPENSSL_BUILD_OUTPUT})
endif()

add_dependencies(OpenSSL::Crypto openssl-build)
add_dependencies(OpenSSL::SSL openssl-build)

# Test OpenSSL using CTest
if(OPENSSL_TEST AND NOT CMAKE_CROSSCOMPILING)
    include(CTest)
    add_test(
        NAME openssl-test
        COMMAND ${OPENSSL_BUILD_TOOL} test VERBOSE_FAILURE=yes HARNESS_JOBS=${NUMBER_OF_THREADS}
        WORKING_DIRECTORY ${openssl_BINARY_DIR}
    )
endif()

# Install OpenSSL
if(OPENSSL_INSTALL)
    # Reuse the build tool options (-j N / /J N, -s / /S, /NOLOGO) so install does not run serially
    list(JOIN OPENSSL_BUILD_OPTIONS " " _openssl_install_options)
    set(OPENSSL_INSTALL_COMMAND "\"${OPENSSL_BUILD_TOOL}\" ${_openssl_install_options} ${OPENSSL_INSTALL_TARGET}")

    if(MSVC AND NOT ASV_WINX AND NOT "/NOLOGO" IN_LIST OPENSSL_BUILD_OPTIONS)
        set(OPENSSL_INSTALL_COMMAND "${OPENSSL_INSTALL_COMMAND} /NOLOGO")
    endif()

    install(CODE
        "execute_process(
            COMMAND ${OPENSSL_INSTALL_COMMAND}
            WORKING_DIRECTORY \"${openssl_BINARY_DIR}\"
            COMMAND_ERROR_IS_FATAL ANY
        )"
    )

    # ASI: make the exported shared OpenSSL::SSL carry OpenSSL::Crypto on Unix
    if(UNIX AND BUILD_SHARED_LIBS)
        install(SCRIPT ${CMAKE_CURRENT_SOURCE_DIR}/cmake/FixOpenSSLConfig.cmake)
    endif()
endif()

if(OPENSSL_INSTALL_CERT)
    if(WIN32)
        parse_makefile(${OPENSSL_MAKEFILE} "OPENSSLDIR_dev" OPENSSL_OPENSSLDIR_DEV)
        parse_makefile(${OPENSSL_MAKEFILE} "OPENSSLDIR_dir" OPENSSL_OPENSSLDIR_DIR)
        set(OPENSSL_OPENSSLDIR ${OPENSSL_OPENSSLDIR_DEV}${OPENSSL_OPENSSLDIR_DIR})
        string(REPLACE "\\" "/" OPENSSL_OPENSSLDIR "${OPENSSL_OPENSSLDIR}")
    else()
        parse_makefile(${OPENSSL_MAKEFILE} "OPENSSLDIR" OPENSSL_OPENSSLDIR)
    endif()

    # Download latest CA certificates
    # https://curl.se/docs/caextract.html
    install(CODE "file(DOWNLOAD https://curl.se/ca/cacert.pem ${OPENSSL_OPENSSLDIR}/cert.pem)")
endif()
