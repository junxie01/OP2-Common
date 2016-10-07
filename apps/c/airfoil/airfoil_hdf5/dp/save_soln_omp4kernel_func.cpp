//
// auto-generated by op2.py
//

void save_soln_omp4_kernel(
  double *data0,
  double *data1,
  int count,
  int num_teams,
  int nthread,
  int direct_save_soln_stride_OP2CONSTANT){

  #pragma omp target teams num_teams(num_teams) thread_limit(nthread) is_device_ptr(data0,data1)
  #pragma omp distribute parallel for schedule(static,1)
  for ( int n_op=0; n_op<count; n_op++ ){
    //variable mapping
    const double *q = &data0[n_op];
    double *qold = &data1[n_op];

    //inline function
      
    for (int n = 0; n < 4; n++)
      qold[n*direct_save_soln_stride_OP2CONSTANT] = q[n*direct_save_soln_stride_OP2CONSTANT];
    //end inline func
  }

}
