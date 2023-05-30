#include <assert.h>
#include "core/tensor.h"
#include "gpu.cuh"
#include "kern/kernel.h"
#include "math.h"
#include "string.h"
#include "utils.h"

namespace inferllm {
namespace gpu {

__global__ void llm_softmax_compute_float_gpu(
        uint32_t n, const float* src, float* dst, uint32_t len_row, uint32_t col) {
    CUDA_KERNEL_LOOP(index, n) {
        const float* psrc = src + index * col;
        float* pdst = dst + index * col;

        float max = -INFINITY;
        for (uint32_t i = 0; i < col; ++i) {
            if (max < psrc[i])
                max = psrc[i];
        }

        float sum = 0.0f;

        for (uint32_t i = 0; i < col; i++) {
            if (psrc[i] == -INFINITY) {
                pdst[i] = 0.0f;
            } else {
                float val = exp(psrc[i] - max);
                sum += val;
                pdst[i] = val;
            }
        }

        sum = 1.0 / sum;
        for (uint32_t j = 0; j < col; j++) {
            pdst[j] = pdst[j] * sum;
        }
    }
}

void llm_softmax_compute_float(
        const float* src, float* dst, uint32_t len_row, uint32_t col) {
    llm_softmax_compute_float_gpu<<<GET_BLOCKS(len_row), CUDA_NUM_THREADS>>>(
            len_row, src, dst, len_row, col);
}

__global__ void llm_norm_compute_float_gpu(
        uint32_t n, const float* src, float* dst, uint32_t seq_len, uint32_t embd) {
    CUDA_KERNEL_LOOP(i, n) {
        const float eps = 1e-5f;
        const float* row = src + i * embd;
        float* out = dst + i * embd;

        float mean = 0.0;
        for (uint32_t j = 0; j < embd; j++) {
            mean += row[j] * row[j];
        }
        mean /= embd;

        const float scale = 1.0 / sqrt(mean + eps);

        for (uint32_t j = 0; j < embd; j++) {
            out[j] = row[j] * scale;
        }
    }
}

void llm_norm_compute_float(
        const float* src, float* dst, uint32_t seq_len, uint32_t embd) {
    llm_norm_compute_float_gpu<<<GET_BLOCKS(seq_len), CUDA_NUM_THREADS>>>(
            seq_len, src, dst, seq_len, embd);
}
void llm_embedding_get_float_float(
        const float* weights, const uint32_t* index, float* dst, uint32_t len_seq,
        uint32_t embd) {
    for (uint32_t i = 0; i < len_seq; ++i) {
        const int row = index[i];
        const int weight_stride = embd;
        memcpy(dst + i * embd, weights + row * weight_stride, embd * sizeof(float));
    }
}

inline void dequantize_row_q4_0_reference(
        const void* __restrict x, float* __restrict y, int k) {}

__global__ void llm_embedding_get_int4_float_gpu(
        uint32_t n, const void* weights, const uint32_t* index_ptr, float* dst,
        uint32_t len_seq, uint32_t embd) {
    CUDA_KERNEL_LOOP(index, n) {
        uint32_t head_loc = index / embd;
        uint32_t nb_loc = (index / QK40) % (embd / QK40);
        uint32_t qk40_loc = index % QK40;

        const int row = index_ptr[head_loc];
        const int weight_stride = embd * sizeof(BlockQ40) / QK40;

        auto x = (const char*)weights + row * weight_stride;

        auto y = dst + head_loc * embd;

        const int nb = embd / QK40;
        const size_t bs = sizeof(float) + QK40 / 2;

        const uint8_t* __restrict pd = ((const uint8_t*)x + 0 * bs);
        const uint8_t* __restrict pb = ((const uint8_t*)x + 0 * bs + sizeof(float));

        // scalar
        const float d = *(const float*)(pd + nb_loc * bs);

        const uint8_t* __restrict pp = pb + nb_loc * bs;

        const uint8_t vi = pp[qk40_loc / 2];

        const int8_t vi0 = vi & 0xf;
        const int8_t vi1 = vi >> 4;

        const float v0 = (vi0 - 8) * d;
        const float v1 = (vi1 - 8) * d;

        // printf("d = %f, vi = %d, vi0 = %d, vi1 = %d, v0 = %f, v1 = %f\n",
        // d, vi, vi0, vi1, v0, v1);

        y[nb_loc * QK40 + qk40_loc + 0] = v0;
        y[nb_loc * QK40 + qk40_loc + 1] = v1;
    }
}

void llm_embedding_get_int4_float(
        const void* weights, const uint32_t* index, float* dst, uint32_t len_seq,
        uint32_t embd) {
    uint32_t count = len_seq * embd;
    llm_embedding_get_int4_float_gpu<<<GET_BLOCKS(count), CUDA_NUM_THREADS>>>(
            count, weights, index, dst, len_seq, embd);
}

struct SiluFunctor {
    __device__ float operator()(uint32_t i, const float* input) const {
        float src = input[i];
        return src / (1.0 + exp(-src));
    }
};

struct GeluFunctor {
    __device__ float operator()(uint32_t i, const float* input) const {
        float src = input[i];
        return 0.5 * src * (1 + tanh(sqrt(2.0 / PI) * (src + PGELU * src * src * src)));
    }
};

struct AddFunctor {
    __device__ float operator()(
            uint32_t i, const float* input1, const float* input2) const {
        return input1[i] + input2[i];
    }
};

struct MulFunctor {
    __device__ float operator()(
            uint32_t i, const float* input1, const float* input2) const {
        return input1[i] + input2[i];
    }
};

void llm_elemwise_compute_float(
        InData<float> srcs, float* dst, size_t len, ElemMode mode) {
    MultiThreadingTask task;
    switch (mode) {
        case ElemMode::Add: {
            const float* src0 = srcs[0];
            const float* src1 = srcs[1];
            LaunchKernel(AddFunctor(), len, dst, src0, src1);
            break;
        }
        case ElemMode::Mul: {
            const float* src0 = srcs[0];
            const float* src1 = srcs[1];

            LaunchKernel(MulFunctor(), len, dst, src0, src1);
            break;
        }
        case ElemMode::Silu: {
            const float* src0 = srcs[0];
            LaunchKernel(SiluFunctor(), len, dst, src0);
            break;
        }
        case ElemMode::Gelu: {
            {
                const float* src0 = srcs[0];
                LaunchKernel(GeluFunctor(), len, dst, src0);
                break;
            }
            default:
                INFER_ASSERT(0, "Not supported.");
        }
    }
}

__global__ void llm_rms_norm_compute_float_gpu(
        const float* src, float* dst, uint32_t seq_len, uint32_t embd) {
    const float eps = 1e-5f;

    CUDA_KERNEL_LOOP(i, seq_len) {
        const float* row = src + i * embd;
        float* out = dst + i * embd;

        float mean = 0.0;
        for (uint32_t j = 0; j < embd; j++) {
            mean += row[j] * row[j];
        }
        mean /= embd;

        const float scale = 1.0 / sqrt(mean + eps);

        for (uint32_t j = 0; j < embd; j++) {
            out[j] = row[j] * scale;
        }
    }
}

void llm_rms_norm_compute_float(
        const float* src, float* dst, uint32_t seq_len, uint32_t embd) {
    llm_rms_norm_compute_float_gpu<<<GET_BLOCKS(seq_len), CUDA_NUM_THREADS>>>(
            src, dst, seq_len, embd);
}

__global__ void llm_rope_compute_float_gpu(
        uint32_t n, float* dst, const float* src0, uint32_t n_past, uint32_t n_rot,
        RotMode m, uint32_t seqlen, uint32_t head, uint32_t embd) {
    int mode = static_cast<int>(m);
    int n_dims = n_rot;
    CUDA_KERNEL_LOOP(index, n) {
        uint32_t half_rot = n_rot / 2;
        uint32_t seq_loc = index / (head * half_rot);
        uint32_t head_loc = (index / half_rot) % head;
        uint32_t rot_loc = index % half_rot;

        const int p = (mode == 0 ? n_past + seq_loc : seq_loc);
        const double theta = pow(10000.0, ((double)-rot_loc) / n_dims);

        const double cos_theta = cos(p * theta);
        const double sin_theta = sin(p * theta);

        const float* const src =
                src0 + seq_loc * head * embd + head_loc * embd + rot_loc;
        float* dst_data = dst + seq_loc * head * embd + head_loc * embd + rot_loc;

        double x0 = src[0];
        double x1 = src[1];
        if (mode == 0) {
            dst_data[0] = x0 * cos_theta - x1 * sin_theta;
            dst_data[1] = x0 * sin_theta + x1 * cos_theta;

        } else {
            if (seq_loc >= n_past) {
                dst_data[0] = x0 * cos_theta - x1 * sin_theta;
                dst_data[1] = x0 * sin_theta + x1 * cos_theta;
            }
        }
    }
}
void llm_rope_compute_float(
        float* dst, const float* src0, uint32_t n_past, uint32_t n_rot, RotMode m,
        uint32_t seqlen, uint32_t head, uint32_t embd) {
    uint32_t count = seqlen * head * (n_rot / 2);

    llm_rope_compute_float_gpu<<<GET_BLOCKS(count), CUDA_NUM_THREADS>>>(
            count, dst, src0, n_past, n_rot, m, seqlen, head, embd);
}

__global__ void llm_elemwise_compute_float_scale_gpu(
        float* src, float* dst, size_t len, float scale) {
    CUDA_KERNEL_LOOP(i, len) {
        dst[i] = src[i] * scale;
    }
}

void llm_elemwise_compute_float_scale(float* src, float* dst, size_t len, float scale) {
    llm_elemwise_compute_float_scale_gpu<<<GET_BLOCKS(len), CUDA_NUM_THREADS>>>(
            src, dst, len, scale);
}

// void llm_matmul_compute_float_float(
//         float* dst, const float* src0, const float* bias, const float* src1, uint32_t M,
//         uint32_t N, uint32_t K, void* workspace, uint32_t size) {
//     const float* src = src1;
//     auto task = [=](const TaskId& id) {
//         for (uint32_t n = id.start; n < id.end; n++) {
//             const float* weight = src0 + n * K;
//             float b = bias ? bias[n] : 0.0f;
//             for (uint32_t m = 0; m < M; m++) {
//                 const float* p_src = src + m * K;
//                 dst[m * N + n] =
//                         vec_vec_dot_float_with_float_reference(K, weight, p_src) + b;
//             }
//         }
//     };
//     return TaskSet{{task, N}};
// }

__global__ void llm_matmul_compute_int4_float_step1_gpu(
        uint32_t n, float* dst, const void* src0, const float* bias, const float* src1,
        uint32_t M, uint32_t N, uint32_t K, void* workspace, uint32_t size) {
    CUDA_KERNEL_LOOP(index, n) {
        uint32_t m_loc = index / (K / QK80);
        uint32_t nb_loc = index % (K / QK80);

        uint32_t weight_q80_stride = K * sizeof(BlockQ80) / sizeof(BlockQ80);

        const float* x = src1 + m_loc * K;
        BlockQ80* y = (BlockQ80*)(static_cast<uint8_t*>(workspace) +
                                  m_loc * weight_q80_stride);

        float amax = 0.0f;  // absolute max
        for (int l = 0; l < QK80; l++) {
            const float v = x[nb_loc * QK80 + l];
            amax = amax > fabsf(v) ? amax : fabsf(v);
        }

        const float d = amax / ((1 << 7) - 1);
        const float id = d ? 1.0f / d : 0.0f;

        y[nb_loc].d = d;
        for (int l = 0; l < QK80; ++l) {
            const float v0 = x[nb_loc * QK80 + l] * id;

            y[nb_loc].qs[l] = roundf(v0);
        }
    }
}

__global__ void llm_matmul_compute_int4_float_step2_gpu(
        uint32_t n, float* dst, const void* src0, const float* bias, const float* src1,
        uint32_t M, uint32_t N, uint32_t K, void* workspace, uint32_t size) {
    CUDA_KERNEL_LOOP(index, n) {
        uint32_t m_loc = index / N;
        uint32_t n_loc = index % N;

        uint32_t weight_q40_stride = K * sizeof(BlockQ40) / sizeof(BlockQ40);
        uint32_t weight_q80_stride = K * sizeof(BlockQ80) / sizeof(BlockQ80);

        int8_t* q_src = static_cast<int8_t*>(workspace);
        const void* q_weight =
                static_cast<const uint8_t*>(src0) + n_loc * weight_q40_stride;
        float b = bias ? bias[n_loc] : 0.0f;
        int8_t* src = q_src + m_loc * weight_q80_stride;

        const BlockQ40* __restrict x = (BlockQ40*)(q_weight);
        const BlockQ80* __restrict y = (BlockQ80*)(src);

        uint32_t nb = K / QK80;
        float sumf = 0.0;
        for (int i = 0; i < nb; i++) {
            const float d0 = x[i].d;
            const float d1 = y[i].d;

            const uint8_t* __restrict p0 = x[i].qs;
            const int8_t* __restrict p1 = y[i].qs;

            int sumi = 0;
            for (int j = 0; j < QK80 / 2; j++) {
                const uint8_t v0 = p0[j];

                const int i0 = (int8_t)(v0 & 0x0F) - 8;
                const int i1 = (int8_t)(v0 >> 4) - 8;

                const int i2 = p1[2 * j + 0];
                const int i3 = p1[2 * j + 1];

                sumi += i0 * i2 + i1 * i3;
            }
            sumf += d0 * d1 * sumi;
        }

        dst[m_loc * N + n_loc] = sumf + b;
    }
}
// compute the softmax of the last dim of src, and store the result in dst
void llm_matmul_compute_int4_float(
        float* dst, const void* src0, const float* bias, const float* src1, uint32_t M,
        uint32_t N, uint32_t K, void* workspace, uint32_t size) {
    //! src0 is quantized weights, weights store in 32 data as block and a
    //! block share the same scale, src1 is featureMap. src0 layout is {N,
    //! K}, src1 layout is {M, K}, the dst is {M, N}
    INFER_ASSERT(sizeof(float) * K <= size, "workspace is not enough.");
    uint32_t weight_q40_stride =
            K * dtype_in_byte(DType::Int4) / dtype_block_size(DType::Int4);
    uint32_t weight_q80_stride =
            K * dtype_in_byte(DType::Int8) / dtype_block_size(DType::Int8);
    //! dequantize input, and store in workspace
    //! becuase the input is small than the weights, quantized the input
    //! will reduce the memory traffic
    uint32_t count1 = M * (K / QK80);

    llm_matmul_compute_int4_float_step1_gpu<<<GET_BLOCKS(count1), CUDA_NUM_THREADS>>>(
            count1, dst, src0, bias, src1, M, N, K, workspace, size);

    uint32_t count2 = M * N;
    llm_matmul_compute_int4_float_step2_gpu<<<GET_BLOCKS(count2), CUDA_NUM_THREADS>>>(
            count2, dst, src0, bias, src1, M, N, K, workspace, size);
}

__global__ void llm_scale_diag_mask_inf_float_gpu(
        uint32_t n, float* dst, const float* src0, float scale, uint32_t n_past,
        uint32_t seqlen, uint32_t head) {
    CUDA_KERNEL_LOOP(index, n) {
        uint32_t seq_loc = (index / (seqlen + n_past)) % seqlen;
        uint32_t len_loc = index % (seqlen + n_past);

        if (len_loc > n_past + seq_loc) {
}
/**
 * dst :head *seq * (seq +nr_past)
 *
 *
 */
void llm_scale_diag_mask_inf_float(
        float* dst, const float* src0, float scale, uint32_t n_past, uint32_t seqlen,
        uint32_t head) {
    uint32_t count = head * seqlen * (n_past + seqlen);
    llm_scale_diag_mask_inf_float_gpu<<<GET_BLOCKS(count), CUDA_NUM_THREADS>>>(
            count, dst, src0, scale, n_past, seqlen, head);
}

void llm_permute_compute_float(
        float* dst, const float* src0, uint32_t dim0, uint32_t dim1, uint32_t dim2,
        std::vector<uint32_t> param) {
    uint32_t axis0 = param[0];
    uint32_t axis1 = param[1];
    uint32_t axis2 = param[2];

    auto task = [=](const TaskId& id) {
        if (axis0 == 1 && axis1 == 0 && axis2 == 2) {
            for (int i0 = 0; i0 < dim0; i0++) {
                for (int i1 = 0; i1 < dim1; i1++) {
                    const float* p_src = src0 + (i0 * dim1 + i1) * dim2;
                    float* p_dst = dst + (i1 * dim0 + i0) * dim2;
                    memcpy(p_dst, p_src, dim2 * sizeof(float));
                }
            }
        }
    };
}
/**
 * dst :head *seqlen *(seql)
 */
__global__ void llm_matmul_compute_with_head_stride_float_gpu(
        uint32_t n, float* dst, const float* srck, const float* srcq, uint32_t seqlen,
        uint32_t embd, uint32_t head, uint32_t nr_past) {
    CUDA_KERNEL_LOOP(index, n) {
        uint32_t sub_embd = embd / head;
        uint32_t length = nr_past + seqlen;
        uint32_t line_stride = embd;
        uint32_t head_loc = index / (seqlen * (seqlen + nr_past));
        uint32_t seq_loc = (index / (seqlen + nr_past)) % seqlen;
        uint32_t line_loc = index % (seqlen + nr_past);

        auto p_srcq = srcq + head_loc * sub_embd + seq_loc * line_stride;
        auto p_srck = srck + head_loc * sub_embd + line_loc * line_stride;
        float sum = 0;

        for (uint32_t k = 0; k < sub_embd; k++) {
            sum += p_srck[k] * p_srcq[k];
        }
        dst[index] = sum;
    }
}

void llm_matmul_compute_with_head_stride_float(
        float* dst, const float* srck, const float* srcq, uint32_t seqlen,
        uint32_t embd, uint32_t head, uint32_t nr_past) {
    // 用于计算query和key的点积
    uint32_t count = seqlen * head * (seqlen + nr_past);
    llm_matmul_compute_with_head_stride_float_gpu<<<
            GET_BLOCKS(count), CUDA_NUM_THREADS>>>(
            count, dst, srck, srcq, seqlen, embd, head, nr_past);
}

/**
 *  dst :seq * head * subdim
 *
 */
__global__ void llm_head_batched_matmul_compute_float_gpu(
        uint32_t n, float* dst, const float* v, const float* qk, uint32_t seqlen,
        uint32_t embd, uint32_t head, uint32_t nr_past) {
    uint32_t sub_embd = embd / head;
    uint32_t length = nr_past + seqlen;
    uint32_t line_stride = embd;
    CUDA_KERNEL_LOOP(index, n) {
        uint32_t seq_loc = index / embd;

        uint32_t head_loc = (index / sub_embd) % head;

        uint32_t sub_embed_loc = index % sub_embd;

        auto p_qk = qk + head_loc * seqlen * length + seq_loc * length;
        auto p_v = v + head_loc * sub_embd + sub_embed_loc;
        float sum = 0;

        for (uint32_t k = 0; k < length; k++) {
            sum += p_v[k * embd] * p_qk[k];
        }
        dst[index] = sum;
    }
}

void llm_head_batched_matmul_compute_float(
        float* dst, const float* v, const float* qk, uint32_t seqlen, uint32_t embd,
        uint32_t head, uint32_t nr_past) {
    uint32_t count = seqlen * embd;
    llm_head_batched_matmul_compute_float_gpu<<<GET_BLOCKS(count), CUDA_NUM_THREADS>>>(
            count, dst, v, qk, seqlen, embd, head, nr_past);
}
}  // namespace gpu
}  // namespace inferllm