# URMA header search path: manual via URMA_ROOT, or fetched from git.
set(URMA_ROOT "" CACHE PATH "URMA lib root (contains core/include, bond/include); empty to fetch from git")

if(URMA_ROOT)
    if(NOT EXISTS "${URMA_ROOT}/core/include/urma_api.h")
        message(FATAL_ERROR
            "URMA_ROOT is set to '${URMA_ROOT}', but urma_api.h was not found. "
            "Point URMA_ROOT at the urma lib dir containing core/include and bond/include.")
    endif()
    set(URMA_INCLUDE_DIR
        "${URMA_ROOT}/core/include"
        "${URMA_ROOT}/bond/include")
    message(STATUS "URMA include dir (from URMA_ROOT): ${URMA_INCLUDE_DIR}")
else()
    include(FetchContent)
    FetchContent_Declare(
            urma
            GIT_REPOSITORY https://atomgit.com/openeuler/umdk.git
            GIT_TAG        v25.12.0.B081
    )
    FetchContent_MakeAvailable(urma)
    message(STATUS "URMA source dir: ${urma_SOURCE_DIR}")
    message(STATUS "URMA binary dir: ${urma_BINARY_DIR}")
    set(URMA_INCLUDE_DIR
        ${urma_SOURCE_DIR}/src/urma/lib/urma/core/include
        ${urma_SOURCE_DIR}/src/urma/lib/urma/bond/include)
    message(STATUS "URMA include dir (fetched): ${URMA_INCLUDE_DIR}")
endif()