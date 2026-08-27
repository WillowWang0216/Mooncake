if(DEFINED UMDK_ROOT AND NOT UMDK_ROOT STREQUAL "")
  if(NOT EXISTS "${UMDK_ROOT}/src/urma/lib/urma/core/include/urma_api.h")
    message(FATAL_ERROR
      "UMDK_ROOT is set to '${UMDK_ROOT}', but urma_api.h was not found. "
      "Point UMDK_ROOT at a UMDK source tree containing src/urma/lib/urma/core/include.")
  endif()

  set(urma_SOURCE_DIR "${UMDK_ROOT}")
  set(urma_INCLUDE_DIR
      "${UMDK_ROOT}/src/urma/lib/urma/core/include"
      "${UMDK_ROOT}/src/urma/lib/urma/bond/include")
  message(STATUS "Using local UMDK source tree: ${urma_SOURCE_DIR}")
else()
  include(FetchContent)

  # UMDK 头文件库
  FetchContent_Declare(
          urma
          GIT_REPOSITORY https://atomgit.com/openeuler/umdk.git
          GIT_TAG        v25.12.0.B081
  )

  FetchContent_MakeAvailable(urma)

  # 输出实际路径，确认位置
  message(STATUS "URMA source dir: ${urma_SOURCE_DIR}")
  message(STATUS "URMA binary dir: ${urma_BINARY_DIR}")

  # 假设 UMDK 头文件在其 include 目录下
  set(urma_INCLUDE_DIR
      ${urma_SOURCE_DIR}/src/urma/lib/urma/core/include
      ${urma_SOURCE_DIR}/src/urma/lib/urma/bond/include)
endif()

# 添加到需要的目标
message(STATUS "urma_INCLUDE_DIR: ${urma_INCLUDE_DIR}")
