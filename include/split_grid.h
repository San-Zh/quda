#pragma once

#include <quda.h>
#include <comm_quda.h>
#include <communicator_quda.h>

#include <gauge_field.h>
#include <color_spinor_field.h>
#include <clover_field.h>

int comm_rank_from_coords(const int *coords);

namespace quda
{

  int inline product(const CommKey &input) { return input[0] * input[1] * input[2] * input[3]; }

  CommKey inline operator+(const CommKey &lhs, const CommKey &rhs)
  {
    CommKey sum;
    for (int d = 0; d < nDim; d++) { sum[d] = lhs[d] + rhs[d]; }
    return sum;
  }

  CommKey inline operator*(const CommKey &lhs, const CommKey &rhs)
  {
    CommKey product;
    for (int d = 0; d < nDim; d++) { product[d] = lhs[d] * rhs[d]; }
    return product;
  }

  CommKey inline operator/(const CommKey &lhs, const CommKey &rhs)
  {
    CommKey quotient;
    for (int d = 0; d < nDim; d++) { quotient[d] = lhs[d] / rhs[d]; }
    return quotient;
  }

  CommKey inline operator%(const CommKey &lhs, const CommKey &rhs)
  {
    CommKey mod;
    for (int d = 0; d < nDim; d++) { mod[d] = lhs[d] % rhs[d]; }
    return mod;
  }

  CommKey inline coordinate_from_index(int index, CommKey dim)
  {
    CommKey coord;
    for (int d = 0; d < nDim; d++) {
      coord[d] = index % dim[d];
      index /= dim[d];
    }
    return coord;
  }

  int inline index_from_coordinate(CommKey coord, CommKey dim)
  {
    return ((coord[3] * dim[2] + coord[2]) * dim[1] + coord[1]) * dim[0] + coord[0];
  }

  template <class F> struct param_mapper {
  };

  template <> struct param_mapper<GaugeField> {
    using type = GaugeFieldParam;
  };

  template <> struct param_mapper<ColorSpinorField> {
    using type = ColorSpinorParam;
  };

  template <> struct param_mapper<CloverField> {
    using type = CloverFieldParam;
  };

  template <class Field>
  void inline split_field(Field &collect_field, std::vector<Field *> &v_base_field, const CommKey &comm_key)
  {
    CommKey full_dim = {comm_dim(0), comm_dim(1), comm_dim(2), comm_dim(3)};
    CommKey full_idx = {comm_coord(0), comm_coord(1), comm_coord(2), comm_coord(3)};

    int rank = comm_rank();
    int total_rank = product(full_dim);

    auto grid_dim = full_dim / comm_key;  // Communicator grid.
    auto block_dim = full_dim / grid_dim; // The full field needs to be partitioned according to the communicator grid.

    int n_replicates = product(comm_key);
    std::vector<void *> v_send_buffer_h(n_replicates, nullptr);
    std::vector<MsgHandle *> v_mh_send(n_replicates, nullptr);

    int n_fields = v_base_field.size();
    if (n_fields == 0) { errorQuda("Empty vector!"); }

    const auto meta = v_base_field[0];

    // Send cycles
    for (int i = 0; i < n_replicates; i++) {
      auto grid_idx = coordinate_from_index(i, comm_key);
      auto block_idx = full_idx / block_dim;

      auto dst_idx = grid_idx * grid_dim + block_idx;

      int dst_rank = comm_rank_from_coords(dst_idx.data());
      int tag = rank * total_rank + dst_rank; // tag = src_rank * total_rank + dst_rank

      // THIS IS A COMMENT: printf("rank %4d -> rank %4d: tag = %4d\n", comm_rank(), dst_rank, tag);
      size_t bytes = meta->TotalBytes();

      v_send_buffer_h[i] = pinned_malloc(bytes);

      v_base_field[i % n_fields]->copy_to_buffer(v_send_buffer_h[i]);

      v_mh_send[i] = comm_declare_send_rank(v_send_buffer_h[i], dst_rank, tag, bytes);
      comm_start(v_mh_send[i]);
    }

    using param_type = typename param_mapper<Field>::type;

    param_type param(*meta);
    Field *buffer_field = Field::Create(param);

    const int *X = meta->X();
    CommKey thread_dim = {X[0], X[1], X[2], X[3]};

    // Receive cycles
    for (int i = 0; i < n_replicates; i++) {
      auto thread_idx = coordinate_from_index(i, comm_key);
      auto src_idx = (full_idx % grid_dim) * block_dim + thread_idx;

      int src_rank = comm_rank_from_coords(src_idx.data());
      int tag = src_rank * total_rank + rank;

      // THIS IS A COMMENT: printf("rank %4d <- rank %4d: tag = %4d\n", comm_rank(), src_rank, tag);
      size_t bytes = buffer_field->TotalBytes();

      void *recv_buffer_h = pinned_malloc(bytes);

      auto mh_recv = comm_declare_recv_rank(recv_buffer_h, src_rank, tag, bytes);

      comm_start(mh_recv);
      comm_wait(mh_recv);

      buffer_field->copy_from_buffer(recv_buffer_h);

      comm_free(mh_recv);
      host_free(recv_buffer_h);

      auto offset = thread_idx * thread_dim;

      quda::copyFieldOffset(collect_field, *buffer_field, offset.data());
    }

    delete buffer_field;

    comm_barrier();

    for (auto &p : v_send_buffer_h) { if (p) { host_free(p); } };
    for (auto &p : v_mh_send) { if (p) { comm_free(p); } };
  }

  template <class Field>
  void inline join_field(std::vector<Field *> &v_base_field, const Field &collect_field, const CommKey &comm_key)
  {
    CommKey full_dim = {comm_dim(0), comm_dim(1), comm_dim(2), comm_dim(3)};
    CommKey full_idx = {comm_coord(0), comm_coord(1), comm_coord(2), comm_coord(3)};

    int rank = comm_rank();
    int total_rank = product(full_dim);

    auto grid_dim = full_dim / comm_key;  // Communicator grid.
    auto block_dim = full_dim / grid_dim; // The full field needs to be partitioned according to the communicator grid.

    int n_replicates = product(comm_key);
    std::vector<void *> v_send_buffer_h(n_replicates, nullptr);
    std::vector<MsgHandle *> v_mh_send(n_replicates, nullptr);

    int n_fields = v_base_field.size();
    if (n_fields == 0) { errorQuda("Empty vector!"); }

    const auto &meta = *(v_base_field[0]);

    using param_type = typename param_mapper<Field>::type;

    param_type param(meta);
    Field *buffer_field = Field::Create(param);

    const int *X = meta.X();
    CommKey thread_dim = {X[0], X[1], X[2], X[3]};

    // Send cycles
    for (int i = 0; i < n_replicates; i++) {

      auto thread_idx = coordinate_from_index(i, comm_key);
      auto dst_idx = (full_idx % grid_dim) * block_dim + thread_idx;

      int dst_rank = comm_rank_from_coords(dst_idx.data());
      int tag = rank * total_rank + dst_rank;

      // THIS IS A COMMENT: printf("rank %4d -> rank %4d: tag = %4d\n", comm_rank(), dst_rank, tag);
      size_t bytes = meta.TotalBytes();

      auto offset = thread_idx * thread_dim;
      quda::copyFieldOffset(*buffer_field, collect_field, offset.data());

      v_send_buffer_h[i] = pinned_malloc(bytes);
      buffer_field->copy_to_buffer(v_send_buffer_h[i]);

      v_mh_send[i] = comm_declare_send_rank(v_send_buffer_h[i], dst_rank, tag, bytes);

      comm_start(v_mh_send[i]);
    }

    // Receive cycles
    for (int i = 0; i < n_replicates; i++) {

      auto grid_idx = coordinate_from_index(i, comm_key);
      auto block_idx = full_idx / block_dim;

      auto src_idx = grid_idx * grid_dim + block_idx;

      int src_rank = comm_rank_from_coords(src_idx.data());
      int tag = src_rank * total_rank + rank;

      // THIS IS A COMMENT: printf("rank %4d <- rank %4d: tag = %4d\n", comm_rank(), src_rank, tag);
      size_t bytes = buffer_field->TotalBytes();

      void *recv_buffer_h = pinned_malloc(bytes);

      auto mh_recv = comm_declare_recv_rank(recv_buffer_h, src_rank, tag, bytes);

      comm_start(mh_recv);
      comm_wait(mh_recv);

      v_base_field[i % n_fields]->copy_from_buffer(recv_buffer_h);

      comm_free(mh_recv);
      host_free(recv_buffer_h);
    }

    delete buffer_field;

    comm_barrier();

    for (auto &p : v_send_buffer_h) { host_free(p); };
    for (auto &p : v_mh_send) { comm_free(p); };
  }

} // namespace quda