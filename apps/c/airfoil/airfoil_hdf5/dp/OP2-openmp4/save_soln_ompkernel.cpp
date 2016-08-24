//
// auto-generated by op2.py
//

//user function
//user function

void save_soln_omp4_kernel(
  double *data0,
  double *data1,
  int count);

// host stub function
void op_par_loop_save_soln(char const *name, op_set set,
  op_arg arg0,
  op_arg arg1){

  int nargs = 2;
  op_arg args[2];

  args[0] = arg0;
  args[1] = arg1;

  // initialise timers
  double cpu_t1, cpu_t2, wall_t1, wall_t2;
  op_timing_realloc(0);
  op_timers_core(&cpu_t1, &wall_t1);
  OP_kernels[0].name      = name;
  OP_kernels[0].count    += 1;


  if (OP_diags>2) {
    printf(" kernel routine w/o indirection:  save_soln");
  }

  op_mpi_halo_exchanges_cuda(set, nargs, args);


  if (set->size >0) {


    //Set up typed device pointers for OpenACC

    double* data0 = (double*)arg0.data_d;
    double* data1 = (double*)arg1.data_d;
    save_soln_omp4_kernel(
      data0,
      data1,
      set->size);

  }

  // combine reduction data
  op_mpi_set_dirtybit_cuda(nargs, args);

  // update kernel record
  op_timers_core(&cpu_t2, &wall_t2);
  OP_kernels[0].time     += wall_t2 - wall_t1;
  OP_kernels[0].transfer += (float)set->size * arg0.size;
  OP_kernels[0].transfer += (float)set->size * arg1.size;
}
