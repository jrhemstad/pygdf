/*
 * Copyright (c) 2018, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#ifndef COLUMN_WRAPPER_H
#define COLUMN_WRAPPER_H

#include <thrust/equal.h>
#include <thrust/logical.h>
#include <bitset>
#include "cudf.h"
#include "rmm/rmm.h"
#include "utilities/bit_util.cuh"
#include "utilities/type_dispatcher.hpp"

#ifndef CUDA_RT_CALL
#define CUDA_RT_CALL(call)                                                    \
  do {                                                                        \
    cudaError_t cudaStatus = (call);                                          \
    if (cudaSuccess != cudaStatus) {                                          \
      fprintf(stderr,                                                         \
              "ERROR: CUDA RT call \"%s\" in line %d of file %s failed with " \
              "%s (%d).\n",                                                   \
              #call, __LINE__, __FILE__, cudaGetErrorString(cudaStatus),      \
              cudaStatus);                                                    \
      exit(1);                                                                \
    }                                                                         \
  } while (0)
#endif

namespace cudf {
namespace test {

template <typename ColumnType>
struct column_wrapper {
  column_wrapper(gdf_size_type column_size) {
    std::vector<ColumnType> host_data(column_size, 0);
    std::vector<gdf_valid_type> host_bitmask(
        gdf_get_num_chars_bitmask(column_size), 0);
    initialize_with_host_data(host_data, host_bitmask);
  }

  column_wrapper(gdf_column const& other_column) : the_column{other_column} {}

  column_wrapper(std::vector<ColumnType> const& host_data,
                 std::vector<gdf_valid_type> const& host_bitmask) {
    initialize_with_host_data(host_data, host_bitmask);
  }

  column_wrapper(std::vector<ColumnType> const& host_data) {
    initialize_with_host_data(host_data);
  }

  template <typename BitInitializerType>
  column_wrapper(std::vector<ColumnType> const& host_data,
                 BitInitializerType bit_initializer) {
    const size_t num_masks = gdf_get_num_chars_bitmask(host_data.size());
    const gdf_size_type num_rows{static_cast<gdf_size_type>(host_data.size())};

    // Initialize the valid mask for this column using the initializer
    std::vector<gdf_valid_type> host_bitmask(num_masks, 0);
    for (gdf_index_type row = 0; row < num_rows; ++row) {
      if (true == bit_initializer(row)) {
        gdf::util::turn_bit_on(host_bitmask.data(), row);
      }
    }
    initialize_with_host_data(host_data, host_bitmask);
  }

  template <typename ValueInitializerType, typename BitInitializerType>
  column_wrapper(gdf_size_type column_size,
                 ValueInitializerType value_initalizer,
                 BitInitializerType bit_initializer) {
    const size_t num_masks = gdf_get_num_chars_bitmask(column_size);

    // Initialize the values and bitmask using the initializers
    std::vector<ColumnType> host_data(column_size);
    std::vector<gdf_valid_type> host_bitmask(num_masks, 0);

    for (gdf_index_type row = 0; row < column_size; ++row) {
      host_data[row] = value_initalizer(row);

      if (true == bit_initializer(row)) {
        gdf::util::turn_bit_on(host_bitmask.data(), row);
      }
    }
    initialize_with_host_data(host_data, host_bitmask);
  }

  ~column_wrapper() {
    RMM_FREE(the_column.data, 0);
    RMM_FREE(the_column.valid, 0);
    the_column.size = 0;
  }

  gdf_column* get() { return &the_column; }
  gdf_column const* get() const { return &the_column; }

  auto to_host() const {
    gdf_size_type const num_masks{gdf_get_num_chars_bitmask(the_column.size)};
    std::vector<ColumnType> host_data;
    std::vector<gdf_valid_type> host_bitmask;

    if (nullptr != the_column.data) {
      host_data.resize(the_column.size);
      CUDA_RT_CALL(cudaMemcpy(host_data.data(), the_column.data,
                              the_column.size * sizeof(ColumnType),
                              cudaMemcpyDeviceToHost));
    }

    if (nullptr != the_column.valid) {
      host_bitmask.resize(num_masks);
      CUDA_RT_CALL(cudaMemcpy(host_bitmask.data(), the_column.valid,
                              num_masks * sizeof(gdf_valid_type),
                              cudaMemcpyDeviceToHost));
    }

    return std::make_tuple(host_data, host_bitmask);
  }

  struct elements_equal {
    gdf_column lhs_col;
    gdf_column rhs_col;

    __host__ __device__ elements_equal(gdf_column lhs, gdf_column rhs)
        : lhs_col{lhs}, rhs_col{rhs} {}

    __device__ bool operator()(gdf_index_type row) {
      bool const lhs_is_valid{gdf_is_valid(lhs_col.valid, row)};
      bool const rhs_is_valid{gdf_is_valid(rhs_col.valid, row)};

      if (lhs_is_valid && rhs_is_valid) {
        return static_cast<ColumnType const*>(lhs_col.data)[row] ==
               static_cast<ColumnType const*>(rhs_col.data)[row];
      }

      // If one value is valid but the other is not
      if (lhs_is_valid xor rhs_is_valid) {
        return false;
      }

      // If both values are invalid, return true
      return true;
    }
  };

  /**---------------------------------------------------------------------------*
   * @brief Compares if another column_wrapper is equal to this wrapper.
   *
   * Treats NULL == NULL
   *
   * @param rhs  The other column_wrapper to check for equality
   * @return true The two columns are equal
   * @return false The two columns are not equal
   *---------------------------------------------------------------------------**/
  bool operator==(column_wrapper<ColumnType> const& rhs) const {
    if (the_column.size != rhs.the_column.size) return false;
    if (the_column.dtype != rhs.the_column.dtype) return false;
    if (the_column.null_count != rhs.the_column.null_count) return false;
    if (the_column.dtype_info.time_unit != rhs.the_column.dtype_info.time_unit)
      return false;

    if (!(the_column.data && rhs.the_column.data))
      return false;  // if one is null but not both

    if (not thrust::all_of(thrust::make_counting_iterator(0),
                           thrust::make_counting_iterator(the_column.size),
                           elements_equal{the_column, rhs.the_column})) {
      return false;
    }

    CUDA_RT_CALL(cudaPeekAtLastError());

    return true;
  }

 private:
  void initialize_with_host_data(
      std::vector<ColumnType> const& host_data,
      std::vector<gdf_valid_type> const& host_bitmask =
          std::vector<gdf_valid_type>{}) {
    // Allocate device storage for gdf_column and copy contents from host_data
    RMM_ALLOC(&(the_column.data), host_data.size() * sizeof(ColumnType), 0);
    CUDA_RT_CALL(cudaMemcpy(the_column.data, host_data.data(),
                            host_data.size() * sizeof(ColumnType),
                            cudaMemcpyHostToDevice));

    // Fill the gdf_column members
    the_column.size = host_data.size();
    the_column.dtype = cudf::type_to_gdf_dtype<ColumnType>::value;
    gdf_dtype_extra_info extra_info;
    extra_info.time_unit = TIME_UNIT_NONE;
    the_column.dtype_info = extra_info;

    // If a validity bitmask vector was passed in, allocate device storage
    // and copy its contents from the host vector
    if (host_bitmask.size() > 0) {
      RMM_ALLOC(&(the_column.valid),
                host_bitmask.size() * sizeof(gdf_valid_type), 0);
      CUDA_RT_CALL(cudaMemcpy(the_column.valid, host_bitmask.data(),
                              host_bitmask.size() * sizeof(gdf_valid_type),
                              cudaMemcpyHostToDevice));
    } else {
      the_column.valid = nullptr;
    }
    set_null_count(&the_column);
  }

  bool compare_bitmasks(gdf_valid_type* lhs, gdf_valid_type* rhs,
                        gdf_size_type num_rows) const {
    gdf_size_type const num_masks{gdf_get_num_chars_bitmask(num_rows)};

    // Last bitmask has to be treated as a special case as not all bits may be
    // defined
    if (not thrust::equal(thrust::cuda::par, lhs, lhs + num_masks - 1, rhs))
      return false;

    // Copy last masks to host
    gdf_valid_type lhs_last_mask{0};
    gdf_valid_type rhs_last_mask{0};

    CUDA_RT_CALL(cudaMemcpy(&lhs_last_mask, &lhs[num_masks - 1],
                            sizeof(gdf_valid_type), cudaMemcpyDeviceToHost));

    CUDA_RT_CALL(cudaMemcpy(&rhs_last_mask, &rhs[num_masks - 1],
                            sizeof(gdf_valid_type), cudaMemcpyDeviceToHost));

    std::bitset<GDF_VALID_BITSIZE> lhs_bitset(lhs_last_mask);
    std::bitset<GDF_VALID_BITSIZE> rhs_bitset(rhs_last_mask);

    gdf_size_type num_bits_last_mask = num_rows % GDF_VALID_BITSIZE;

    if (0 == num_bits_last_mask) num_bits_last_mask = GDF_VALID_BITSIZE;

    for (gdf_size_type i = 0; i < num_bits_last_mask; ++i) {
      if (lhs_bitset[i] != rhs_bitset[i]) return false;
    }
    return true;
  }

  gdf_column the_column;
};  // namespace test

}  // namespace test
}  // namespace cudf
#endif
