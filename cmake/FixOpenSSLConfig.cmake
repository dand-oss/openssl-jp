# ASI: install-time fix for OpenSSL's exported lib/cmake/OpenSSL/OpenSSLConfig.cmake
#
# In the Unix shared-library branch, exporters/cmake/OpenSSLConfig.cmake.in assumes
# libssl.so "implies" libcrypto.so: OpenSSL::SSL does not link OpenSSL::Crypto and
# OPENSSL_LIBRARIES is libssl alone. A consumer calling libcrypto itself (ERR_*,
# X509_*, EVP_*) is then underlinked. The static and Windows import-library branches
# already carry Crypto, and FindOpenSSL.cmake sets OPENSSL_LIBRARIES to ssl + crypto.
#
# Run with install(SCRIPT); CMAKE_INSTALL_PREFIX is set by cmake --install.

set(_config "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/cmake/OpenSSL/OpenSSLConfig.cmake")
if(NOT EXISTS "${_config}")
    message(FATAL_ERROR "FixOpenSSLConfig: ${_config} was not installed")
endif()

file(READ "${_config}" _text)
set(_broken "  set(OPENSSL_LIBRARIES \${OPENSSL_SSL_LIBRARIES})\n")
string(CONCAT _fixed
    "  set(OPENSSL_LIBRARIES \${OPENSSL_SSL_LIBRARIES} \${OPENSSL_CRYPTO_LIBRARIES})\n"
    "  # ASI: libssl consumers also call libcrypto - link it, as the static branch does\n"
    "  set_property(TARGET OpenSSL::SSL PROPERTY INTERFACE_LINK_LIBRARIES OpenSSL::Crypto)\n"
)

string(FIND "${_text}" "${_broken}" _at)
if(_at EQUAL -1)
    string(FIND "${_text}" "set(OPENSSL_LIBRARIES \${OPENSSL_SSL_LIBRARIES} \${OPENSSL_CRYPTO_LIBRARIES})" _done)
    if(_done EQUAL -1)
        message(FATAL_ERROR "FixOpenSSLConfig: shared OPENSSL_LIBRARIES line not found in ${_config}; "
                            "OpenSSL's exporter changed, update this fix")
    endif()
else()
    string(REPLACE "${_broken}" "${_fixed}" _text "${_text}")
    file(WRITE "${_config}" "${_text}")
    message(STATUS "FixOpenSSLConfig: OpenSSL::SSL now links OpenSSL::Crypto in ${_config}")
endif()
