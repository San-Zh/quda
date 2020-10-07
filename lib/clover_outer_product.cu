#include <dslash_quda.h>
#include <tunable_nd.h>
#include <instantiate.h>
#include <kernels/clover_outer_product.cuh>

namespace quda {

  enum OprodKernelType { INTERIOR, EXTERIOR };

  template <typename Float, int nColor, QudaReconstructType recon> class CloverForce : public TunableKernel1D {
    using real = typename mapper<Float>::type;
    template <int dim = -1> using Arg = CloverForceArg<Float, nColor, recon, dim>;
    GaugeField &force;
    const GaugeField &U;
    const ColorSpinorField &inA;
    const ColorSpinorField &inB;
    const ColorSpinorField &inC;
    const ColorSpinorField &inD;
    const int parity;
    const real coeff;
    OprodKernelType kernel;
    int dir;
    unsigned int minThreads() const { return kernel == INTERIOR ? inB.VolumeCB() : inB.GhostFaceCB()[dir]; }

  public:
    CloverForce(const GaugeField &U, GaugeField &force, const ColorSpinorField& inA,
                const ColorSpinorField& inB, const ColorSpinorField& inC, const ColorSpinorField& inD,
                int parity, double coeff) :
      TunableKernel1D(force),
      force(force),
      U(U),
      inA(inA),
      inB(inB),
      inC(inC),
      inD(inD),
      parity(parity),
      coeff(static_cast<real>(coeff))
    {
      char aux2[TuneKey::aux_n];
      strcpy(aux2, aux);
      strcat(aux, ",interior");
      kernel = INTERIOR;
      apply(0);

      for (int i=3; i>=0; i--) {
        if (!commDimPartitioned(i)) continue;
        strcpy(aux, aux2);
        strcat(aux, ",exterior");
        if (dir==0) strcat(aux, ",dir=0");
        else if (dir==1) strcat(aux, ",dir=1");
        else if (dir==2) strcat(aux, ",dir=2");
        else if (dir==3) strcat(aux, ",dir=3");
        kernel = EXTERIOR;
        dir = i;
        apply(0);
      }
    }

    void apply(const qudaStream_t &stream)
    {
      TuneParam tp = tuneLaunch(*this, getTuning(), getVerbosity());

      if (kernel == INTERIOR) {
        launch<Interior>(tp, stream, Arg<>(force, U, inA, inB, inC, inD, parity, coeff));
      } else if (kernel == EXTERIOR) {
        switch (dir) {
        case 0: launch<Exterior>(tp, stream, Arg<0>(force, U, inA, inB, inC, inD, parity, coeff)); break;
        case 1: launch<Exterior>(tp, stream, Arg<1>(force, U, inA, inB, inC, inD, parity, coeff)); break;
        case 2: launch<Exterior>(tp, stream, Arg<2>(force, U, inA, inB, inC, inD, parity, coeff)); break;
        case 3: launch<Exterior>(tp, stream, Arg<3>(force, U, inA, inB, inC, inD, parity, coeff)); break;
        default: errorQuda("Unexpected direction %d", dir);
        }
      }
    }

    void preTune() { force.backup(); }
    void postTune() { force.restore(); }

    // spin trace + multiply-add (ignore spin-project)
    long long flops() const { return minThreads() * (144 + 234) * (kernel == INTERIOR ? 4 : 1); }

    long long bytes() const
    {
      if (kernel == INTERIOR) {
	return inA.Bytes() + inC.Bytes() + 4*(inB.Bytes() + inD.Bytes()) + force.Bytes() + U.Bytes() / 2;
      } else {
	return minThreads() * (nColor * (4 * 2 + 2 * 2) + 2 * force.Reconstruct() + U.Reconstruct())
          * sizeof(Float);
      }
    }
  }; // CloverForce

  void exchangeGhost(cudaColorSpinorField &a, int parity, int dag) {
    // this sets the communications pattern for the packing kernel
    int comms[QUDA_MAX_DIM] = { commDimPartitioned(0), commDimPartitioned(1),
                                commDimPartitioned(2), commDimPartitioned(3) };
    setPackComms(comms);

    // need to enable packing in temporal direction to get spin-projector correct
    pushKernelPackT(true);

    // first transfer src1
    qudaDeviceSynchronize();

    MemoryLocation location[2*QUDA_MAX_DIM] = {Device, Device, Device, Device, Device, Device, Device, Device};
    a.pack(1, 1-parity, dag, Nstream-1, location, Device);

    qudaDeviceSynchronize();

    for (int i=3; i>=0; i--) {
      if (commDimPartitioned(i)) {
	// Initialize the host transfer from the source spinor
	a.gather(1, dag, 2*i);
      } // commDim(i)
    } // i=3,..,0

    qudaDeviceSynchronize(); comm_barrier();

    for (int i=3; i>=0; i--) {
      if (commDimPartitioned(i)) {
	a.commsStart(1, 2*i, dag);
      }
    }

    for (int i=3; i>=0; i--) {
      if (commDimPartitioned(i)) {
	a.commsWait(1, 2*i, dag);
	a.scatter(1, dag, 2*i);
      }
    }

    qudaDeviceSynchronize();
    popKernelPackT(); // restore packing state

    a.bufferIndex = (1 - a.bufferIndex);
    comm_barrier();
  }

  void computeCloverForce(GaugeField &force, const GaugeField &U, std::vector<ColorSpinorField *> &x,
                          std::vector<ColorSpinorField *> &p, std::vector<double> &coeff)
  {
#ifdef GPU_CLOVER_DIRAC
    checkNative(*x[0], *p[0], force, U);
    checkPrecision(*x[0], *p[0], force, U);

    int dag = 1;

    for (unsigned int i=0; i<x.size(); i++) {
      static_cast<cudaColorSpinorField&>(x[i]->Even()).allocateGhostBuffer(1);
      static_cast<cudaColorSpinorField&>(x[i]->Odd()).allocateGhostBuffer(1);
      static_cast<cudaColorSpinorField&>(p[i]->Even()).allocateGhostBuffer(1);
      static_cast<cudaColorSpinorField&>(p[i]->Odd()).allocateGhostBuffer(1);

      for (int parity=0; parity<2; parity++) {
	ColorSpinorField& inA = (parity&1) ? p[i]->Odd() : p[i]->Even();
	ColorSpinorField& inB = (parity&1) ? x[i]->Even(): x[i]->Odd();
	ColorSpinorField& inC = (parity&1) ? x[i]->Odd() : x[i]->Even();
	ColorSpinorField& inD = (parity&1) ? p[i]->Even(): p[i]->Odd();

        exchangeGhost(static_cast<cudaColorSpinorField&>(inB), parity, dag);
        exchangeGhost(static_cast<cudaColorSpinorField&>(inD), parity, 1-dag);

        instantiate<CloverForce, ReconstructNo12>(U, force, inA, inB, inC, inD, parity, coeff[i]);
      }
    }
#else // GPU_CLOVER_DIRAC not defined
   errorQuda("Clover Dirac operator has not been built!");
#endif

  } // computeCloverForce

} // namespace quda
