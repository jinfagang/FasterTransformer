/*
 * Copyright (c) 2022, NVIDIA CORPORATION.  All rights reserved.
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

#ifndef CUDART_VERSION
#error CUDART_VERSION Undefined!
#elif (CUDART_VERSION >= 11050)
#include <cub/cub.cuh>
#else
#include "3rdparty/cub/cub.cuh"
#endif

#include "src/fastertransformer/kernels/stop_criteria_kernels.h"
#include "src/fastertransformer/utils/cuda_utils.h"
#include "src/fastertransformer/utils/memory_utils.h"

namespace fastertransformer {

constexpr int LENGTH_CRITERION_BLOCKSIZE = 256;

__global__ void stop_words_criterion(const int* output_ids,
                                     const int* parent_ids,
                                     const int* stop_words,
                                     bool*      finished,
                                     size_t     id_offset,
                                     size_t     stop_words_len,
                                     int        batch_size,
                                     int        beam_width,
                                     int        step)
{
    const int id        = blockIdx.x * blockDim.x + threadIdx.x;
    const int batch_idx = blockIdx.y / beam_width;
    const int beam_idx  = blockIdx.y % beam_width;

    const int* base_stop_words = stop_words + batch_idx * 2 * stop_words_len;
    const int* base_offsets    = base_stop_words + stop_words_len;

    if (id >= stop_words_len || base_offsets[id] < 0) {
        return;
    }

    const int item_end   = base_offsets[id];
    const int item_start = (id > 0) ? base_offsets[id - 1] : 0;
    const int item_size  = item_end - item_start;

    /* The single-token case unconditionally bans the token */
    bool should_stop = false;

    /* Enough previously generated tokens to look for a match */
    if (step + 1 >= item_size) {
        should_stop            = true;
        int        parent_id   = beam_idx;
        const bool gather_beam = beam_width > 1;

        for (int token_idx = item_size - 1; token_idx >= 0; token_idx--) {
            const int previous_token = output_ids[(step - (item_size - 1) + token_idx) * batch_size * beam_width
                                                  + id_offset + batch_idx * beam_width + parent_id];

            if (previous_token != base_stop_words[item_start + token_idx]) {
                should_stop = false;
                break;
            }
            if (gather_beam) {
                parent_id = parent_ids[(step - (item_size - 1) + token_idx) * beam_width * batch_size + id_offset
                                       + batch_idx * beam_width + parent_id];

                if (parent_id < 0 || parent_id >= beam_width) {
                    should_stop = false;
                    break;
                }
            }
        }
    }

    if (should_stop) {
        finished[batch_idx * beam_width + beam_idx] = true;
    }
}

void invokeStopWordsCriterion(const int*   output_ids,
                              const int*   parent_ids,
                              const int*   stop_words,
                              bool*        finished,
                              size_t       id_offset,
                              size_t       stop_words_len,
                              int          batch_size,
                              int          beam_width,
                              int          step,
                              cudaStream_t stream)
{
    // Check if we have sampled a word from the stop_words list. If so, stop the sequence.
    dim3 block, grid;
    block.x = min(((stop_words_len + 32 - 1) / 32) * 32, 256UL);
    grid.x  = (stop_words_len + block.x - 1) / block.x;
    grid.y  = batch_size * beam_width;

    stop_words_criterion<<<grid, block, 0, stream>>>(
        output_ids, parent_ids, stop_words, finished, id_offset, stop_words_len, batch_size, beam_width, step);
    sync_check_cuda_error();
}

__global__ void length_criterion(bool*           finished,
                                 bool*           should_stop,
                                 int*            finished_sum,
                                 const uint32_t* sequence_limit_length,
                                 int             batch_size,
                                 int             beam_width,
                                 int             step)
{
    typedef cub::BlockReduce<int, LENGTH_CRITERION_BLOCKSIZE> BlockReduce;
    __shared__ typename BlockReduce::TempStorage              temp_storage;

    const int index = blockIdx.x * blockDim.x + threadIdx.x;

    // const int beam_idx  = index % beam_width;
    const int batch_idx = index / beam_width;

    if (index >= batch_size * beam_width) {
        return;
    }

    finished[index] |= step >= sequence_limit_length[batch_idx];

    int agg = BlockReduce(temp_storage).Sum((int)finished[index]);
    atomicAdd(finished_sum, agg);
}

void invokeLengthCriterion(bool*           finished,
                           bool*           should_stop,
                           int*            finished_sum,
                           const uint32_t* sequence_limit_length,
                           int             batch_size,
                           int             beam_width,
                           int             step,
                           cudaStream_t    stream)
{
    // Check if we have attained the sequence length limit. If so, stop the sequence.
    // In addition, check if all sequences are stopped and return the result in should_stop
    dim3 block{LENGTH_CRITERION_BLOCKSIZE};
    dim3 grid{(batch_size * beam_width + block.x - 1) / block.x};

    length_criterion<<<grid, block, 0, stream>>>(
        finished, should_stop, finished_sum, sequence_limit_length, batch_size, beam_width, step);

    int h_finished_sum = 0;
    cudaD2Hcpy(&h_finished_sum, finished_sum, 1);

    *should_stop = h_finished_sum == batch_size * beam_width;
}

}  // namespace fastertransformer
