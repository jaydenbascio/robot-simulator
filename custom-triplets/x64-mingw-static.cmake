include("../vcpkg/triplets/community/x64-mingw-static.cmake")

# URDF does not include stdint on its own, which can throw nasty errors
set(VCPKG_CXX_FLAGS "${VCPKG_CXX_FLAGS} -include stdint.h")
set(VCPKG_C_FLAGS "${VCPKG_C_FLAGS} -include stdint.h")
