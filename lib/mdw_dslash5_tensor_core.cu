#include <color_spinor_field.h>
#include <dslash_quda.h>
#include <color_spinor_field_order.h>
#include <index_helper.cuh>
#include <dslash_quda.h>
#include <inline_ptx.h>
#include <shared_memory_cache_helper.cuh>
#include <math_helper.cuh>

#if (__COMPUTE_CAPABILITY__ >= 700)
#include <cublas_v2.h>
#include <mma.h>
#endif

namespace quda {

#if defined (GPU_DOMAIN_WALL_DIRAC) && (__COMPUTE_CAPABILITY__ >= 700)
/*
  static void set_shared_memory_on_volta(const void* f, const char* name){
    cudaDeviceProp device_prop;
    cudaGetDeviceProperties( &device_prop, 0 );
    if(device_prop.major < 7) return;

    auto found = qudaFuncSetAttribute(f, cudaFuncAttributeMaxDynamicSharedMemorySize, 96*1024);
    printfQuda("Found %s: %s\n", name, cudaGetErrorString(found));

    found = qudaFuncSetAttribute(f, cudaFuncAttributePreferredSharedMemoryCarveout, 100);
    printfQuda("Found %s: %s\n", name, cudaGetErrorString(found));

    cudaFuncAttributes cfa;
    found = cudaFuncGetAttributes(&cfa, f);
    printfQuda("Found %s: %s\n", name, cudaGetErrorString(found));

    printfQuda("Actual maximum:         %d\n", (int)cfa.maxDynamicSharedSizeBytes);
    printfQuda("Actual maximum percent: %d\n", (int)cfa.preferredShmemCarveout);
  }
*/  
  template<class T>
  struct TensorCoreSharedMemory
  {
    __device__ inline operator T*()
    {
      extern __shared__ int __smem[];
      return (T*)__smem;
    }

    __device__ inline operator const T*() const
    {
      extern __shared__ int __smem[];
      return (T*)__smem;
    }
  };

  /**
    @brief Structure containing zMobius / Zolotarev coefficients

    FIXME
    - fix flops counters
    - use kappa notation and not b/c for consistency with other codes and sanity
  */
  template <typename real>
    struct coeff_5 {
      complex<real> a[QUDA_MAX_DWF_LS]; // xpay coefficients
      complex<real> b[QUDA_MAX_DWF_LS];
      complex<real> c[QUDA_MAX_DWF_LS];
    };

  constexpr int size = 4096;
  static __constant__ char mobius_d[size]; // constant buffer used for Mobius coefficients for GPU kernel
  static char mobius_h[size];              // constant buffer used for Mobius coefficients for CPU kernel

  /**
    @brief Helper function for grabbing the constant struct, whether
    we are on the GPU or CPU.
   */
  template <typename real>
    inline __device__ __host__ const coeff_5<real>* coeff() {
#ifdef __CUDA_ARCH__
      return reinterpret_cast<const coeff_5<real>*>(mobius_d);
#else
      return reinterpret_cast<const coeff_5<real>*>(mobius_h);
#endif
    }

  template <typename real, Dslash5Type, typename Arg> struct coeff_type {
    typedef real type;
    const Arg &arg;
    __device__ __host__ coeff_type(const Arg &arg) : arg(arg) { }
    __device__ __host__ real a(int s) { return arg.a; }
    __device__ __host__ real b(int s) { return arg.b; }
    __device__ __host__ real c(int s) { return arg.c; }
  };

  template <typename real, typename Arg> struct coeff_type<real,M5_INV_ZMOBIUS,Arg> {
    typedef complex<real> type;
    __device__ __host__ coeff_type(const Arg &arg) { }
    __device__ __host__ complex<real> a(int s) { return coeff<real>()->a[s]; }
    __device__ __host__ complex<real> b(int s) { return coeff<real>()->b[s]; }
    __device__ __host__ complex<real> c(int s) { return coeff<real>()->c[s]; }
  };
  
  /**
    @brief Parameter structure for applying the Dslash
  */
  template<int Ls_>
  struct Dslash5TensorCoreArg {
    typedef typename colorspinor_mapper<short, 4, 3>::type F;
    typedef typename mapper<short>::type real;

    F out;                  // output vector field
    const F in;             // input vector field
    const F x;              // auxiliary input vector field
    const int nParity;      // number of parities we're working on
    const int volume_cb;    // checkerboarded volume
    const int volume_4d_cb; // 4-d checkerboarded volume
    const int_fastdiv Ls;   // length of 5th dimension

    const real m_f;         // fermion mass parameter
    const real m_5;         // Wilson mass shift

    const bool dagger;      // dagger
    const bool xpay;        // whether we are doing xpay or not

    real b;                 // real constant Mobius coefficient
    real c;                 // real constant Mobius coefficient
    real a;                 // real xpay coefficient

    Dslash5Type type;

    Dslash5TensorCoreArg(ColorSpinorField &out, const ColorSpinorField &in, const ColorSpinorField &x,
        double m_f, double m_5, const Complex *b_5_, const Complex *c_5_, double a_, bool dagger, Dslash5Type type)
      : out(out), in(in), x(x), nParity(in.SiteSubset()),
      volume_cb(in.VolumeCB()), volume_4d_cb(volume_cb/Ls_), Ls(Ls_),
      m_f(m_f), m_5(m_5), a(a_), dagger(dagger), xpay(a_ == 0.0 ? false : true), type(type)
    {
      if(in.Nspin() != 4){
        errorQuda("nSpin = %d not support", in.Nspin());
      }
      
      if (!in.isNative() || !out.isNative()) errorQuda("Unsupported field order out=%d in=%d\n", out.FieldOrder(), in.FieldOrder());

      if (sizeof(coeff_5<real>) > size) errorQuda("Coefficient buffer too large at %lu bytes\n", sizeof(coeff_5<real>));
      coeff_5<real> *coeff = reinterpret_cast<coeff_5<real>*>(&mobius_h);
      auto *a_5 =  coeff->a;
      auto *b_5 =  coeff->b;
      auto *c_5 =  coeff->c;

      switch(type){
        case M5_INV_MOBIUS:
          b = -(c_5_[0].real() * (4.0 + m_5) - 1.0) / (b_5_[0].real() * (4.0 + m_5) + 1.0);
          c = 0.5 / ( 1.0 + std::pow(b,(int)Ls) * m_f );
          a *= pow(0.5 / (b_5_[0].real() * (m_5 + 4.0) + 1.0), 2);
          break;
        default:
          errorQuda("Unknown Dslash5Type %d", type);
      }

      cudaMemcpyToSymbolAsync(mobius_d, mobius_h, sizeof(coeff_5<real>), 0, cudaMemcpyHostToDevice, streams[Nstream-1]);

    }
  };

  // matrix a for m5inv: column major, M/M_sm(size/padded size) by k
  // (spin,Ls) by (spin,Ls), where left most index is the fastest changing one(spin).
  // TODO: fix the dagger/non-dagger?
  template<int block_dim_x, int Ls_, int M_sm, bool dagger, class Arg>
  __device__ inline void construct_matrix_a_m5inv(Arg& arg, half* sm_a){
    const float k = arg.b;
    const float inv = arg.c;
 
    int offset_k = threadIdx.y*4;
    int x = threadIdx.x;
    
    while(x < Ls_){
      int offset_m = x*4;
      int exp;
      exp = x>threadIdx.y ? Ls_-x+threadIdx.y : threadIdx.y-x;
      float factorR = inv*__fast_pow(k, exp) * ( x>threadIdx.y ? -arg.m_f : static_cast<float>(1.0) );
      exp = x<threadIdx.y ? Ls_-threadIdx.y+x : x-threadIdx.y;
      float factorL = inv*__fast_pow(k, exp) * ( x<threadIdx.y ? -arg.m_f : static_cast<float>(1.0) );
 
      sm_a[ (offset_k+0)*(M_sm)+(offset_m+0) ] = factorR + factorL;
      sm_a[ (offset_k+0)*(M_sm)+(offset_m+1) ] = static_cast<half>(0.0f);
      sm_a[ (offset_k+0)*(M_sm)+(offset_m+2) ] = factorR - factorL;
      sm_a[ (offset_k+0)*(M_sm)+(offset_m+3) ] = static_cast<half>(0.0f);
      
      sm_a[ (offset_k+1)*(M_sm)+(offset_m+0) ] = static_cast<half>(0.0f);
      sm_a[ (offset_k+1)*(M_sm)+(offset_m+1) ] = factorR + factorL;
      sm_a[ (offset_k+1)*(M_sm)+(offset_m+2) ] = static_cast<half>(0.0f);
      sm_a[ (offset_k+1)*(M_sm)+(offset_m+3) ] = factorR - factorL;
      
      sm_a[ (offset_k+2)*(M_sm)+(offset_m+0) ] = factorR - factorL;
      sm_a[ (offset_k+2)*(M_sm)+(offset_m+1) ] = static_cast<half>(0.0f);
      sm_a[ (offset_k+2)*(M_sm)+(offset_m+2) ] = factorR + factorL;
      sm_a[ (offset_k+2)*(M_sm)+(offset_m+3) ] = static_cast<half>(0.0f);
      
      sm_a[ (offset_k+3)*(M_sm)+(offset_m+0) ] = static_cast<half>(0.0f);
      sm_a[ (offset_k+3)*(M_sm)+(offset_m+1) ] = factorR - factorL;
      sm_a[ (offset_k+3)*(M_sm)+(offset_m+2) ] = static_cast<half>(0.0f);
      sm_a[ (offset_k+3)*(M_sm)+(offset_m+3) ] = factorR + factorL; 
    
      x += block_dim_x;
    }
  } 

  // Load data(scaled short values and scale) from global memory to shared memroy.
  // (spin,Ls) by (complex,color,4d), where left most index is the fastest changing one(spin and complex).
  template<int N_sm, class Arg>
  __device__ inline float load_matrix_b_tex(Arg& arg, half2* sm_b, int sid){
    constexpr int N_sm_d2 = N_sm/2;
    float4 in_tex;
    
    in_tex = tex1Dfetch<float4>(arg.in.tex, 0*arg.volume_cb + sid); 
    sm_b[ (threadIdx.y*4+0)*N_sm_d2+3*threadIdx.x+0 ] = __floats2half2_rn(in_tex.x, in_tex.y);
    sm_b[ (threadIdx.y*4+0)*N_sm_d2+3*threadIdx.x+1 ] = __floats2half2_rn(in_tex.z, in_tex.w);
    
    in_tex = tex1Dfetch<float4>(arg.in.tex, 1*arg.volume_cb + sid); 
    sm_b[ (threadIdx.y*4+0)*N_sm_d2+3*threadIdx.x+2 ] = __floats2half2_rn(in_tex.x, in_tex.y);
    sm_b[ (threadIdx.y*4+1)*N_sm_d2+3*threadIdx.x+0 ] = __floats2half2_rn(in_tex.z, in_tex.w);
    
    in_tex = tex1Dfetch<float4>(arg.in.tex, 2*arg.volume_cb + sid); 
    sm_b[ (threadIdx.y*4+1)*N_sm_d2+3*threadIdx.x+1 ] = __floats2half2_rn(in_tex.x, in_tex.y);
    sm_b[ (threadIdx.y*4+1)*N_sm_d2+3*threadIdx.x+2 ] = __floats2half2_rn(in_tex.z, in_tex.w);
    
    in_tex = tex1Dfetch<float4>(arg.in.tex, 3*arg.volume_cb + sid); 
    sm_b[ (threadIdx.y*4+2)*N_sm_d2+3*threadIdx.x+0 ] = __floats2half2_rn(in_tex.x, in_tex.y);
    sm_b[ (threadIdx.y*4+2)*N_sm_d2+3*threadIdx.x+1 ] = __floats2half2_rn(in_tex.z, in_tex.w);
    
    in_tex = tex1Dfetch<float4>(arg.in.tex, 4*arg.volume_cb + sid); 
    sm_b[ (threadIdx.y*4+2)*N_sm_d2+3*threadIdx.x+2 ] = __floats2half2_rn(in_tex.x, in_tex.y);
    sm_b[ (threadIdx.y*4+3)*N_sm_d2+3*threadIdx.x+0 ] = __floats2half2_rn(in_tex.z, in_tex.w);
    
    in_tex = tex1Dfetch<float4>(arg.in.tex, 5*arg.volume_cb + sid); 
    sm_b[ (threadIdx.y*4+3)*N_sm_d2+3*threadIdx.x+1 ] = __floats2half2_rn(in_tex.x, in_tex.y);
    sm_b[ (threadIdx.y*4+3)*N_sm_d2+3*threadIdx.x+2 ] = __floats2half2_rn(in_tex.z, in_tex.w);
    
    return tex1Dfetch<float>(arg.in.texNorm, sid);
  } 

  __device__ inline short2 __half22short2_rn(const half2 input){
    return make_short2(__half2short_rn(input.x), __half2short_rn(input.y));
  }
  __device__ inline half __half_max_abs_half2__(half max, const half2 input){
    static constexpr uint32_t mask = ~((0x1u<<31) + (0x1u<<15)); // 01111111 11111111 01111111 11111111 
    // Set the fisrt bit of the half to 0.
    uint32_t input_masked = *reinterpret_cast<const uint32_t*>(&input) & mask;
    max = __hgt(max, reinterpret_cast<half2*>(&input_masked)->x) ? max : reinterpret_cast<half2*>(&input_masked)->x;
    max = __hgt(max, reinterpret_cast<half2*>(&input_masked)->y) ? max : reinterpret_cast<half2*>(&input_masked)->y;
    return max;
  }

  // Store results(scaled short values and scale) in shared memroy to global memroy.
  template<int N_sm, class Arg>
  __device__ inline void store_matrix_c(Arg& arg, half2* sm_b, int sid, float scale){
    half max_ = (half)0.0f;
    constexpr int N_sm_d2 = N_sm/2;
    
    max_ = __half_max_abs_half2__(max_, sm_b[ (threadIdx.y*4+0)*N_sm_d2+3*threadIdx.x+0 ]);
    max_ = __half_max_abs_half2__(max_, sm_b[ (threadIdx.y*4+0)*N_sm_d2+3*threadIdx.x+1 ]);
    max_ = __half_max_abs_half2__(max_, sm_b[ (threadIdx.y*4+0)*N_sm_d2+3*threadIdx.x+2 ]);
    max_ = __half_max_abs_half2__(max_, sm_b[ (threadIdx.y*4+1)*N_sm_d2+3*threadIdx.x+0 ]);
    max_ = __half_max_abs_half2__(max_, sm_b[ (threadIdx.y*4+1)*N_sm_d2+3*threadIdx.x+1 ]);
    max_ = __half_max_abs_half2__(max_, sm_b[ (threadIdx.y*4+1)*N_sm_d2+3*threadIdx.x+2 ]);
    max_ = __half_max_abs_half2__(max_, sm_b[ (threadIdx.y*4+2)*N_sm_d2+3*threadIdx.x+0 ]);
    max_ = __half_max_abs_half2__(max_, sm_b[ (threadIdx.y*4+2)*N_sm_d2+3*threadIdx.x+1 ]);
    max_ = __half_max_abs_half2__(max_, sm_b[ (threadIdx.y*4+2)*N_sm_d2+3*threadIdx.x+2 ]);
    max_ = __half_max_abs_half2__(max_, sm_b[ (threadIdx.y*4+3)*N_sm_d2+3*threadIdx.x+0 ]);
    max_ = __half_max_abs_half2__(max_, sm_b[ (threadIdx.y*4+3)*N_sm_d2+3*threadIdx.x+1 ]);
    max_ = __half_max_abs_half2__(max_, sm_b[ (threadIdx.y*4+3)*N_sm_d2+3*threadIdx.x+2 ]);

    arg.out.norm[sid] = __half2float(max_)*scale;
    
    const half2 max_short_div_max2_ = __half2half2( __hdiv(fixedMaxValue<short>::value, max_) );

    short4* out = reinterpret_cast<short4*>(arg.out.field);
    short2 a, b;
    
    a = __half22short2_rn(__hmul2(sm_b[ (threadIdx.y*4+0)*N_sm_d2+3*threadIdx.x+0 ], max_short_div_max2_));
    b = __half22short2_rn(__hmul2(sm_b[ (threadIdx.y*4+0)*N_sm_d2+3*threadIdx.x+1 ], max_short_div_max2_));
    out[sid + 0*arg.volume_cb] = make_short4(a.x, a.y, b.x, b.y); 
    
    a = __half22short2_rn(__hmul2(sm_b[ (threadIdx.y*4+0)*N_sm_d2+3*threadIdx.x+2 ], max_short_div_max2_));
    b = __half22short2_rn(__hmul2(sm_b[ (threadIdx.y*4+1)*N_sm_d2+3*threadIdx.x+0 ], max_short_div_max2_));
    out[sid + 1*arg.volume_cb] = make_short4(a.x, a.y, b.x, b.y); 
    
    a = __half22short2_rn(__hmul2(sm_b[ (threadIdx.y*4+1)*N_sm_d2+3*threadIdx.x+1 ], max_short_div_max2_));
    b = __half22short2_rn(__hmul2(sm_b[ (threadIdx.y*4+1)*N_sm_d2+3*threadIdx.x+2 ], max_short_div_max2_));
    out[sid + 2*arg.volume_cb] = make_short4(a.x, a.y, b.x, b.y); 
    
    a = __half22short2_rn(__hmul2(sm_b[ (threadIdx.y*4+2)*N_sm_d2+3*threadIdx.x+0 ], max_short_div_max2_));
    b = __half22short2_rn(__hmul2(sm_b[ (threadIdx.y*4+2)*N_sm_d2+3*threadIdx.x+1 ], max_short_div_max2_));
    out[sid + 3*arg.volume_cb] = make_short4(a.x, a.y, b.x, b.y); 
    
    a = __half22short2_rn(__hmul2(sm_b[ (threadIdx.y*4+2)*N_sm_d2+3*threadIdx.x+2 ], max_short_div_max2_));
    b = __half22short2_rn(__hmul2(sm_b[ (threadIdx.y*4+3)*N_sm_d2+3*threadIdx.x+0 ], max_short_div_max2_));
    out[sid + 4*arg.volume_cb] = make_short4(a.x, a.y, b.x, b.y); 
    
    a = __half22short2_rn(__hmul2(sm_b[ (threadIdx.y*4+3)*N_sm_d2+3*threadIdx.x+1 ], max_short_div_max2_));
    b = __half22short2_rn(__hmul2(sm_b[ (threadIdx.y*4+3)*N_sm_d2+3*threadIdx.x+2 ], max_short_div_max2_));
    out[sid + 5*arg.volume_cb] = make_short4(a.x, a.y, b.x, b.y);  
  } 

  // "reload" version of wmma gemm. Matrix a is loaded when needed.
  // It is a waste of time but save register usage.
  template<int block_dim_x, int Ls_, int M, int N, int M_sm, int N_sm>
  __device__ inline void wmma_gemm_reload(half* sm_a, half* sm_b, half* sm_c){
    constexpr int WMMA_M = 16;
    constexpr int WMMA_N = 16;
    constexpr int WMMA_K = 16;
    
    constexpr int tm_dim = M/WMMA_M;
    constexpr int tn_dim = N/WMMA_N;
    
    constexpr int total_warp = block_dim_x*Ls_/32;
    
    static_assert( (tm_dim*tn_dim)%total_warp==0, "(tm_dim*tn_dim)%%total_warp==0\n" );
    static_assert( tn_dim%(tm_dim*tn_dim/total_warp)==0, "tn_dim%%(tm_dim*tn_dim/total_warp)==0\n" );
    
    const int this_warp = (threadIdx.y*block_dim_x+threadIdx.x)/32;
    
    constexpr int total_tile = tm_dim*tn_dim;
    
    constexpr int warp_cycle = total_tile/total_warp;
    const int warp_m = this_warp*warp_cycle/tn_dim;
    #pragma unroll
    for(int c = 0; c < warp_cycle; c++){
      // Set up the wmma stuff
      nvcuda::wmma::fragment<nvcuda::wmma::matrix_a, WMMA_M, WMMA_N, WMMA_K, half, nvcuda::wmma::col_major> a_frag;
      nvcuda::wmma::fragment<nvcuda::wmma::matrix_b, WMMA_M, WMMA_N, WMMA_K, half, nvcuda::wmma::row_major> b_frag;
      nvcuda::wmma::fragment<nvcuda::wmma::accumulator, WMMA_M, WMMA_N, WMMA_K, half> c_frag;

      // The logical warp assigned to each part of the matrix.
      const int phys_warp_index = this_warp*warp_cycle+c;
      const int warp_n = phys_warp_index-warp_m*tn_dim;
      // eg. for 12 warps:
      // 000|111|222|333
      // 444|555|666|777
      // 888|999|000|111
      
      // Zero the initial acc.
      nvcuda::wmma::fill_fragment(c_frag, static_cast<half>(0.0f));
      
      #pragma unroll
      for( int k = 0; k < tm_dim; k++ ){
        const int a_row = warp_m*WMMA_M;
        const int a_col = k*WMMA_K;
        const int b_row = k*WMMA_K;
        const int b_col = warp_n*WMMA_N;
    
        // Load Matrix
        nvcuda::wmma::load_matrix_sync(a_frag, sm_a+a_row+a_col*M_sm, M_sm);
        nvcuda::wmma::load_matrix_sync(b_frag, sm_c+b_col+b_row*N_sm, N_sm);
        // Perform the matrix multiplication
        nvcuda::wmma::mma_sync(c_frag, a_frag, b_frag, c_frag);
      } 
    
        int c_row = warp_m*WMMA_M;
        int c_col = warp_n*WMMA_N;
    
        nvcuda::wmma::store_matrix_sync(sm_c+c_col+c_row*N_sm, c_frag, N_sm, nvcuda::wmma::mem_row_major);
    }
  } 
  
  // "preload" version of wmma gemm. Matrix a is preloaded before hand.
  // It saves time but uses more registers.
  template<int block_dim_x, int Ls_, int M, int N, int M_sm, int N_sm, class T>
  __device__ inline void wmma_gemm_preload(T* a_frag, half* sm_b, half* sm_c){
    constexpr int WMMA_M = 16;
    constexpr int WMMA_N = 16;
    constexpr int WMMA_K = 16;
    
    constexpr int tm_dim = M/WMMA_M;
    constexpr int tn_dim = N/WMMA_N;
    
    constexpr int total_warp = block_dim_x*Ls_/32;
    
    static_assert( (tm_dim*tn_dim)%total_warp==0, "(tm_dim*tn_dim)%%total_warp==0\n" );
    static_assert( tn_dim%(tm_dim*tn_dim/total_warp)==0, "tn_dim%%(tm_dim*tn_dim/total_warp)==0\n" );
    
    const int this_warp = (threadIdx.y*block_dim_x+threadIdx.x)/32;
    
    constexpr int total_tile = tm_dim*tn_dim;
    
    constexpr int warp_cycle = total_tile/total_warp;
    const int warp_m = this_warp*warp_cycle/tn_dim;
    #pragma unroll
    for(int c = 0; c < warp_cycle; c++){
      // Set up the wmma stuff
      nvcuda::wmma::fragment<nvcuda::wmma::matrix_b, WMMA_M, WMMA_N, WMMA_K, half, nvcuda::wmma::row_major> b_frag;
      nvcuda::wmma::fragment<nvcuda::wmma::accumulator, WMMA_M, WMMA_N, WMMA_K, half> c_frag;

      // The logical warp assigned to each part of the matrix.
      const int phys_warp_index = this_warp*warp_cycle+c;
      const int warp_n = phys_warp_index-warp_m*tn_dim;
      // eg. for 12 warps:
      // 000|111|222|333
      // 444|555|666|777
      // 888|999|000|111
      
      // Zero the initial acc.
      nvcuda::wmma::fill_fragment(c_frag, static_cast<half>(0.0f));
      
      #pragma unroll
      for( int k = 0; k < tm_dim; k++ ){
        const int b_row = k*WMMA_K;
        const int b_col = warp_n*WMMA_N;
    
        // Load Matrix
        nvcuda::wmma::load_matrix_sync(b_frag, sm_c+b_col+b_row*N_sm, N_sm);
        // Perform the matrix multiplication
        nvcuda::wmma::mma_sync(c_frag, a_frag[k], b_frag, c_frag);
      } 
    
        int c_row = warp_m*WMMA_M;
        int c_col = warp_n*WMMA_N;
    
        nvcuda::wmma::store_matrix_sync(sm_c+c_col+c_row*N_sm, c_frag, N_sm, nvcuda::wmma::mem_row_major);
    }
  } 

// The following two are the actual kernels. Since there is no "static_if" to use two version 
// are implemented explicitly.
// TODO: Maybe someone smart people could have a better idea? Or c++49 will have a "static_if"?

  /**
    @brief Tensor core kernel for applying the M5inv operator: reload version
  */
  template<int block_dim_x, int Ls_, bool dagger, bool xpay, class Arg>
  __global__ void dslash5inv_tensor_core_reload(Arg arg)
  {
    float scale;

    TensorCoreSharedMemory<half2> shared_memory_data;
    
    constexpr int M = 4*Ls_;
    constexpr int N = 6*block_dim_x;
    
    constexpr int sm_m_pad_size = 0;
    constexpr int sm_n_pad_size = 16;
    
    constexpr int N_sm = N + sm_n_pad_size;
    constexpr int M_sm = M + sm_m_pad_size;
    
    half2* sm_b = shared_memory_data;
    half*  sm_c = (half*)sm_b;
    half*  sm_a = sm_c+M*N_sm;

    { // Construct matrix A
      construct_matrix_a_m5inv<block_dim_x, Ls_, M_sm, dagger, Arg>(arg, sm_a);
    } // Construct matrix A
    
    __syncthreads();
   
    bool idle = false;
    int s4_base = blockIdx.x*blockDim.x; // base.
    int s4, sid;
  
    while(s4_base < arg.volume_4d_cb){
      
      s4 = s4_base + threadIdx.x;
      sid = threadIdx.y*arg.volume_4d_cb + s4;
      
      if (s4 >= arg.volume_4d_cb){
        idle = true;
      }
    
      if(!idle){
        scale = load_matrix_b_tex<N_sm, Arg>(arg, sm_b, sid);
      }
      
      __syncthreads();
    
      { // wmma.h
        wmma_gemm_reload<block_dim_x, Ls_, M, N, M_sm, N_sm>(sm_a, sm_c, sm_c);        
      } // wmma.h
      
      __syncthreads();
    
      if(!idle){
         store_matrix_c<N_sm, Arg>(arg, sm_b, sid, scale);
      }
    
      s4_base += gridDim.x*blockDim.x;
    
    } // while
  }
  
  /**
    @brief Tensor core kernel for applying the M5inv operator: preload version
  */
  template<int block_dim_x, int Ls_, bool dagger, bool xpay, class Arg>
  __global__ void dslash5inv_tensor_core_preload(Arg arg)
  {
    float scale;

    TensorCoreSharedMemory<half2> shared_memory_data;
    
    constexpr int M = 4*Ls_;
    constexpr int N = 6*block_dim_x;
    
    constexpr int sm_m_pad_size = 0;
    constexpr int sm_n_pad_size = 16;
    
    constexpr int N_sm = N + sm_n_pad_size;
    constexpr int M_sm = M + sm_m_pad_size;
    
    half2* sm_b = shared_memory_data;
    half*  sm_c = (half*)sm_b;
    half*  sm_a = sm_c+M*N_sm;

    { // Construct matrix A
      construct_matrix_a_m5inv<block_dim_x, Ls_, M_sm, dagger, Arg>(arg, sm_a);
    } // Construct matrix A
    
    __syncthreads();
   
    bool idle = false;
    int s4_base = blockIdx.x*blockDim.x; // base.
    int s4, sid;
 
    constexpr int WMMA_M = 16;
    constexpr int WMMA_N = 16;
    constexpr int WMMA_K = 16;
    
    constexpr int tm_dim = M/WMMA_M;
    constexpr int tn_dim = N/WMMA_N;
    
    constexpr int total_warp = block_dim_x*Ls_/32;
    const int this_warp = (threadIdx.y*block_dim_x+threadIdx.x)/32;
    
    constexpr int total_tile = tm_dim*tn_dim;
    
    constexpr int warp_cycle = total_tile/total_warp;
    const int warp_m = this_warp*warp_cycle/tn_dim;
     
    typedef typename nvcuda::wmma::fragment<nvcuda::wmma::matrix_a, WMMA_M, WMMA_N, WMMA_K, half, nvcuda::wmma::col_major> a_type;
    a_type a_frag[tm_dim];
    #pragma unroll
    for( int k = 0; k < tm_dim; k++ ){
      const int a_row = warp_m*WMMA_M;
      const int a_col = k*WMMA_K;
      // Load Matrix
      nvcuda::wmma::load_matrix_sync(a_frag[k], sm_a+a_row+a_col*M_sm, M_sm);
    } 
  
    while(s4_base < arg.volume_4d_cb){
      
      s4 = s4_base + threadIdx.x;
      sid = threadIdx.y*arg.volume_4d_cb + s4;
      
      if (s4 >= arg.volume_4d_cb){
        idle = true;
      }
    
      if(!idle){
        scale = load_matrix_b_tex<N_sm, Arg>(arg, sm_b, sid);
      }
      
      __syncthreads();
    
      { // wmma.h
        wmma_gemm_preload<block_dim_x, Ls_, M, N, M_sm, N_sm>(a_frag, sm_c, sm_c);        
      } // wmma.h
      
      __syncthreads();
    
      if(!idle){
        store_matrix_c<N_sm, Arg>(arg, sm_b, sid, scale);
      }
    
      s4_base += gridDim.x*blockDim.x;
    
    } // while
  }
 
  template<int Ls_, class Arg>
  class Dslash5TensorCore : public TunableVectorYZ {

    protected:
      Arg &arg;
      const ColorSpinorField &meta;
      static constexpr bool shared = true; // whether to use shared memory cache blocking for M5inv

      /** Whether to use variable or fixed coefficient algorithm.  Must be true if using ZMOBIUS */
      static constexpr bool var_inverse = true;

      long long flops() const {
        long long Ls = Ls_;
        long long bulk = (Ls-2)*(meta.Volume()/Ls);
        long long wall = 2*meta.Volume()/Ls;
        long long n = meta.Ncolor() * meta.Nspin();

        long long flops_ = 0;
        switch (arg.type) {
          case M5_INV_MOBIUS: // FIXME flops
            //flops_ = ((2 + 8 * n) * Ls + (arg.xpay ? 4ll : 0)) * meta.Volume();
            flops_ = (144 * Ls + (arg.xpay ? 4ll : 0)) * meta.Volume();
            break;
          default:
            errorQuda("Unknown Dslash5Type %d", arg.type);
        }

        return flops_;
      }

      long long bytes() const {
        // long long Ls = meta.X(4);
        switch (arg.type) {
          case M5_INV_MOBIUS:
            return arg.out.Bytes() + arg.in.Bytes() + (arg.xpay ? arg.x.Bytes() : 0);
          default: 
            errorQuda("Unknown Dslash5Type %d", arg.type);
        }
        return 0ll;
      }

      virtual bool tuneGridDim() const { return true; }
      virtual bool tuneAuxDim() const { return true; }
      virtual bool tuneSharedBytes() const { return true; }
      unsigned int minThreads() const { return arg.volume_4d_cb; }
  
      unsigned int shared_bytes_per_block(int x, int y) const { 
        // (Ls*4) by (Ls*4), (Ls*4) by (volume_4d*6 + 16)
        return ( (y*4)*(y*4+0)+(y*4)*(x*6+16) )*2; // 4*4*2 TODO: fix this!
      }
   
      virtual bool advanceBlockDim(TuneParam &param) const
      {
        if( param.block.x < max_block_size() ){
          param.block.x += step_block_size();
          param.shared_bytes = shared_bytes_per_block(param.block.x, param.block.y); 
          return true;
        }else{
          return false;
        }
      }
      
      virtual bool advanceGridDim(TuneParam &param) const
      {
        const unsigned int max_blocks = maxGridSize();
        const int step = deviceProp.multiProcessorCount;
        param.grid.x += step;
        if (param.grid.x > max_blocks) {
          return false;
        } else {
          param.block.x = min_block_size();
          param.shared_bytes = shared_bytes_per_block(param.block.x, param.block.y); 
          return true;
        }
      }
      
      virtual bool advanceAux(TuneParam &param) const
      {
        if (param.aux.x < 1) {
          param.aux.x++;
          // We have updated the "aux" so reset all other parameters. 
          param.grid.x = minGridSize();
          param.block.x = min_block_size();
          param.shared_bytes = shared_bytes_per_block(param.block.x, param.block.y); 
          return true;
        } else {
          param.aux.x = 0;
          return false;
        }
      }

      virtual unsigned int maxGridSize() const { return 32*deviceProp.multiProcessorCount; }
      virtual unsigned int minGridSize() const { return deviceProp.multiProcessorCount; }
      unsigned int min_block_size() const { return  8; }
      unsigned int max_block_size() const { return 64; }
      unsigned int step_block_size() const { return  8; }

      // overloaded to return max dynamic shared memory if doing shared-memory inverse
      unsigned int maxSharedBytesPerBlock() const {
        if (shared && (arg.type == M5_INV_DWF || arg.type == M5_INV_MOBIUS || arg.type == M5_INV_ZMOBIUS) ) {
          return maxDynamicSharedBytesPerBlock();
        } else {
          return TunableVectorYZ::maxSharedBytesPerBlock();
        }
      }

    public:
      Dslash5TensorCore(Arg &arg, const ColorSpinorField &meta)
        : TunableVectorYZ(arg.Ls, arg.nParity), arg(arg), meta(meta)
      {
        strcpy(aux, meta.AuxString());
        if (arg.dagger) strcat(aux, ",Dagger");
        if (arg.xpay) strcat(aux,",xpay");
        switch (arg.type) {
          case M5_INV_MOBIUS:
            strcat(aux, ",m5inv_mobius_tensor_core");
            break;
          default: 
            errorQuda("Unknown Dslash5Type %d", arg.type);
        }
      }
      virtual ~Dslash5TensorCore() { }

      template<typename T>
      inline void launch(T *f, const TuneParam &tp, Arg &arg, const cudaStream_t &stream) {
        // static bool init = false;
        if ( shared ) {
          // if inverse kernel uses shared memory then maximize total shared memory pool
          setMaxDynamicSharedBytesPerBlock(f);
          // set_shared_memory_on_volta((const void*)f, "Some Function");
          // init = true;
        }
        void *args[] = { &arg };
        qudaLaunchKernel((const void *)f, tp.grid, tp.block, args, tp.shared_bytes, stream);
      }

      void apply(const cudaStream_t &stream) {
        // By its name we ONLY have a GPU version
        // TuneParam tp = tuneLaunch(*this, getTuning(), getVerbosity());
        TuneParam tp = tuneLaunch(*this, getTuning(), QUDA_DEBUG_VERBOSE);
        if(tp.aux.x == 0){ // preload, NO reload
          switch(arg.type){
            case M5_INV_MOBIUS:
              switch(tp.block.x){
                case  8:
                  if (arg.xpay){ 
                    arg.dagger ?
                      launch(dslash5inv_tensor_core_preload< 8, Ls_, true, true, Arg>, tp, arg, stream) :
                      launch(dslash5inv_tensor_core_preload< 8, Ls_,false, true, Arg>, tp, arg, stream) ;
                  }else{          
                    arg.dagger ?
                      launch(dslash5inv_tensor_core_preload< 8, Ls_, true,false, Arg>, tp, arg, stream) :
                      launch(dslash5inv_tensor_core_preload< 8, Ls_,false,false, Arg>, tp, arg, stream) ;
                  }
                  break;
                case 16:
                  if (arg.xpay){ 
                    arg.dagger ?
                      launch(dslash5inv_tensor_core_preload<16, Ls_, true, true, Arg>, tp, arg, stream) :
                      launch(dslash5inv_tensor_core_preload<16, Ls_,false, true, Arg>, tp, arg, stream) ;
                  }else{          
                    arg.dagger ?
                      launch(dslash5inv_tensor_core_preload<16, Ls_, true,false, Arg>, tp, arg, stream) :
                      launch(dslash5inv_tensor_core_preload<16, Ls_,false,false, Arg>, tp, arg, stream) ;
                  }
                  break;
                case 24:
                  if(arg.xpay){ 
                    arg.dagger ?
                      launch(dslash5inv_tensor_core_preload<24, Ls_, true, true, Arg>, tp, arg, stream) :
                      launch(dslash5inv_tensor_core_preload<24, Ls_,false, true, Arg>, tp, arg, stream) ;
                  }else{
                    arg.dagger ?
                      launch(dslash5inv_tensor_core_preload<24, Ls_, true,false, Arg>, tp, arg, stream) :
                      launch(dslash5inv_tensor_core_preload<24, Ls_,false,false, Arg>, tp, arg, stream) ;
                  }
                  break;
                case 32:
                  if(arg.xpay){ 
                    arg.dagger ?
                      launch(dslash5inv_tensor_core_preload<32, Ls_, true, true, Arg>, tp, arg, stream) :
                      launch(dslash5inv_tensor_core_preload<32, Ls_,false, true, Arg>, tp, arg, stream) ;
                  }else{
                    arg.dagger ?
                      launch(dslash5inv_tensor_core_preload<32, Ls_, true,false, Arg>, tp, arg, stream) :
                      launch(dslash5inv_tensor_core_preload<32, Ls_,false,false, Arg>, tp, arg, stream) ;
                  }
                  break;
                case 40:
                  if(arg.xpay){ 
                    arg.dagger ?
                      launch(dslash5inv_tensor_core_preload<40, Ls_, true, true, Arg>, tp, arg, stream) :
                      launch(dslash5inv_tensor_core_preload<40, Ls_,false, true, Arg>, tp, arg, stream) ;
                  }else{
                    arg.dagger ?
                      launch(dslash5inv_tensor_core_preload<40, Ls_, true,false, Arg>, tp, arg, stream) :
                      launch(dslash5inv_tensor_core_preload<40, Ls_,false,false, Arg>, tp, arg, stream) ;
                  }
                  break;
                case 48:
                  if(arg.xpay){ 
                    arg.dagger ?
                      launch(dslash5inv_tensor_core_preload<48, Ls_, true, true, Arg>, tp, arg, stream) :
                      launch(dslash5inv_tensor_core_preload<48, Ls_,false, true, Arg>, tp, arg, stream) ;
                  }else{
                    arg.dagger ?
                      launch(dslash5inv_tensor_core_preload<48, Ls_, true,false, Arg>, tp, arg, stream) :
                      launch(dslash5inv_tensor_core_preload<48, Ls_,false,false, Arg>, tp, arg, stream) ;
                  }
                  break;
                case 56:
                  if(arg.xpay){ 
                    arg.dagger ?
                      launch(dslash5inv_tensor_core_preload<56, Ls_, true, true, Arg>, tp, arg, stream) :
                      launch(dslash5inv_tensor_core_preload<56, Ls_,false, true, Arg>, tp, arg, stream) ;
                  }else{
                    arg.dagger ?
                      launch(dslash5inv_tensor_core_preload<56, Ls_, true,false, Arg>, tp, arg, stream) :
                      launch(dslash5inv_tensor_core_preload<56, Ls_,false,false, Arg>, tp, arg, stream) ;
                  }
                  break;
                case 64:
                  if(arg.xpay){ 
                    arg.dagger ?
                      launch(dslash5inv_tensor_core_preload<64, Ls_, true, true, Arg>, tp, arg, stream) :
                      launch(dslash5inv_tensor_core_preload<64, Ls_,false, true, Arg>, tp, arg, stream) ;
                  }else{
                    arg.dagger ?
                      launch(dslash5inv_tensor_core_preload<64, Ls_, true,false, Arg>, tp, arg, stream) :
                      launch(dslash5inv_tensor_core_preload<64, Ls_,false,false, Arg>, tp, arg, stream) ;
                  }
                  break;
                default:
                  errorQuda("NOT valid blockDim.x(=%d)\n", tp.block.x);
              }
              break;
            default: 
              errorQuda("Unknown Dslash5Type %d", arg.type);
          }
        }else{ // tp.aux.x
          // RELOAD
          switch(arg.type){
            case M5_INV_MOBIUS:
              switch(tp.block.x){
                case  8:
                  if (arg.xpay){ 
                    arg.dagger ?
                      launch(dslash5inv_tensor_core_reload< 8, Ls_, true, true, Arg>, tp, arg, stream) :
                      launch(dslash5inv_tensor_core_reload< 8, Ls_,false, true, Arg>, tp, arg, stream) ;
                  }else{          
                    arg.dagger ?
                      launch(dslash5inv_tensor_core_reload< 8, Ls_, true,false, Arg>, tp, arg, stream) :
                      launch(dslash5inv_tensor_core_reload< 8, Ls_,false,false, Arg>, tp, arg, stream) ;
                  }
                  break;
                case 16:
                  if (arg.xpay){ 
                    arg.dagger ?
                      launch(dslash5inv_tensor_core_reload<16, Ls_, true, true, Arg>, tp, arg, stream) :
                      launch(dslash5inv_tensor_core_reload<16, Ls_,false, true, Arg>, tp, arg, stream) ;
                  }else{          
                    arg.dagger ?
                      launch(dslash5inv_tensor_core_reload<16, Ls_, true,false, Arg>, tp, arg, stream) :
                      launch(dslash5inv_tensor_core_reload<16, Ls_,false,false, Arg>, tp, arg, stream) ;
                  }
                  break;
                case 24:
                  if(arg.xpay){ 
                    arg.dagger ?
                      launch(dslash5inv_tensor_core_reload<24, Ls_, true, true, Arg>, tp, arg, stream) :
                      launch(dslash5inv_tensor_core_reload<24, Ls_,false, true, Arg>, tp, arg, stream) ;
                  }else{
                    arg.dagger ?
                      launch(dslash5inv_tensor_core_reload<24, Ls_, true,false, Arg>, tp, arg, stream) :
                      launch(dslash5inv_tensor_core_reload<24, Ls_,false,false, Arg>, tp, arg, stream) ;
                  }
                  break;
                case 32:
                  if(arg.xpay){ 
                    arg.dagger ?
                      launch(dslash5inv_tensor_core_reload<32, Ls_, true, true, Arg>, tp, arg, stream) :
                      launch(dslash5inv_tensor_core_reload<32, Ls_,false, true, Arg>, tp, arg, stream) ;
                  }else{
                    arg.dagger ?
                      launch(dslash5inv_tensor_core_reload<32, Ls_, true,false, Arg>, tp, arg, stream) :
                      launch(dslash5inv_tensor_core_reload<32, Ls_,false,false, Arg>, tp, arg, stream) ;
                  }
                  break;
                case 40:
                  if(arg.xpay){ 
                    arg.dagger ?
                      launch(dslash5inv_tensor_core_reload<40, Ls_, true, true, Arg>, tp, arg, stream) :
                      launch(dslash5inv_tensor_core_reload<40, Ls_,false, true, Arg>, tp, arg, stream) ;
                  }else{
                    arg.dagger ?
                      launch(dslash5inv_tensor_core_reload<40, Ls_, true,false, Arg>, tp, arg, stream) :
                      launch(dslash5inv_tensor_core_reload<40, Ls_,false,false, Arg>, tp, arg, stream) ;
                  }
                  break;
                case 48:
                  if(arg.xpay){ 
                    arg.dagger ?
                      launch(dslash5inv_tensor_core_reload<48, Ls_, true, true, Arg>, tp, arg, stream) :
                      launch(dslash5inv_tensor_core_reload<48, Ls_,false, true, Arg>, tp, arg, stream) ;
                  }else{
                    arg.dagger ?
                      launch(dslash5inv_tensor_core_reload<48, Ls_, true,false, Arg>, tp, arg, stream) :
                      launch(dslash5inv_tensor_core_reload<48, Ls_,false,false, Arg>, tp, arg, stream) ;
                  }
                  break;
                case 56:
                  if(arg.xpay){ 
                    arg.dagger ?
                      launch(dslash5inv_tensor_core_reload<56, Ls_, true, true, Arg>, tp, arg, stream) :
                      launch(dslash5inv_tensor_core_reload<56, Ls_,false, true, Arg>, tp, arg, stream) ;
                  }else{
                    arg.dagger ?
                      launch(dslash5inv_tensor_core_reload<56, Ls_, true,false, Arg>, tp, arg, stream) :
                      launch(dslash5inv_tensor_core_reload<56, Ls_,false,false, Arg>, tp, arg, stream) ;
                  }
                  break;
                case 64:
                  if(arg.xpay){ 
                    arg.dagger ?
                      launch(dslash5inv_tensor_core_reload<64, Ls_, true, true, Arg>, tp, arg, stream) :
                      launch(dslash5inv_tensor_core_reload<64, Ls_,false, true, Arg>, tp, arg, stream) ;
                  }else{
                    arg.dagger ?
                      launch(dslash5inv_tensor_core_reload<64, Ls_, true,false, Arg>, tp, arg, stream) :
                      launch(dslash5inv_tensor_core_reload<64, Ls_,false,false, Arg>, tp, arg, stream) ;
                  }
                  break;
                default:
                  errorQuda("NOT valid blockDim.x(=%d)\n", tp.block.x);
              }
              break;
            default: 
              errorQuda("Unknown Dslash5Type %d", arg.type);
          }
        } // tp.aux.x
      }

      void initTuneParam(TuneParam &param) const {
        TunableVectorYZ::initTuneParam(param);
        param.block = dim3(min_block_size(), arg.Ls, 1); // Ls must be contained in the block
        param.grid = dim3(minGridSize(), 1, 1);
        param.shared_bytes = shared_bytes_per_block(param.block.x, param.block.y); 
        param.aux.x = 0;
      }

      void defaultTuneParam(TuneParam &param) const {
        initTuneParam(param);
      }

      TuneKey tuneKey() const { return TuneKey(meta.VolString(), typeid(*this).name(), aux); }
  };

#endif // defined (GPU_DOMAIN_WALL_DIRAC) && (__COMPUTE_CAPABILITY__ >= 700)
  
  // Apply the 5th dimension dslash operator to a colorspinor field
  // out = Dslash5 * in
  
  void apply_dslash5_tensor_core(ColorSpinorField &out, const ColorSpinorField &in, const ColorSpinorField &x,
      double m_f, double m_5, const Complex* b_5, const Complex* c_5, double a, bool dagger, Dslash5Type type)
  {
#if defined (GPU_DOMAIN_WALL_DIRAC) && (__COMPUTE_CAPABILITY__ >= 700)
    if (in.DWFPCtype() != QUDA_4D_PC) errorQuda("ONLY 4D preconditioned fields are supported");
    checkLocation(out, in);     // check all locations match
  
    if( checkPrecision(out, in) == QUDA_HALF_PRECISION && in.Ncolor() == 3){
      // switch for Ls
      switch(in.X(4)){
        case 8:
          {
            Dslash5TensorCoreArg<8> arg(out, in, x, m_f, m_5, b_5, c_5, a, dagger, type);
            Dslash5TensorCore<8, Dslash5TensorCoreArg<8> > dslash(arg, in);
            dslash.apply(streams[Nstream-1]);
          }
        break;
        case 12:
          {
            Dslash5TensorCoreArg<12> arg(out, in, x, m_f, m_5, b_5, c_5, a, dagger, type);
            Dslash5TensorCore<12, Dslash5TensorCoreArg<12> > dslash(arg, in);
            dslash.apply(streams[Nstream-1]);
          }
        break;
        case 16:
          {
            Dslash5TensorCoreArg<16> arg(out, in, x, m_f, m_5, b_5, c_5, a, dagger, type);
            Dslash5TensorCore<16, Dslash5TensorCoreArg<16> > dslash(arg, in);
            dslash.apply(streams[Nstream-1]);
          }
        break;
        case 20:
          {
            Dslash5TensorCoreArg<20> arg(out, in, x, m_f, m_5, b_5, c_5, a, dagger, type);
            Dslash5TensorCore<20, Dslash5TensorCoreArg<20> > dslash(arg, in);
            dslash.apply(streams[Nstream-1]);
          }
        break;
        case 24:
          {
            Dslash5TensorCoreArg<24> arg(out, in, x, m_f, m_5, b_5, c_5, a, dagger, type);
            Dslash5TensorCore<24, Dslash5TensorCoreArg<24> > dslash(arg, in);
            dslash.apply(streams[Nstream-1]);
          }
        break;
        default: 
          errorQuda("Ls = %d is NOT supported.\n", in.X(4));
      }
    }else{
      errorQuda("Tensor core implemtation ONLY supports HALF precision and n_color = 3.\n");
    }
#else
    errorQuda("Domain wall dslash WITH tensor cores has not been built");
#endif
  }

} // namespace quda
