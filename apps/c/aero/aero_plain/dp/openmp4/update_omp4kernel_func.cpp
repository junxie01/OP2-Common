//
// auto-generated by op2.py
//

void update_omp4_kernel(
  double *data0,
  int dat0size,
  double *data1,
  int dat1size,
  double *data2,
  int dat2size,
  double *arg3,
  int count,
  int num_teams,
  int nthread){

  double arg3_l = *arg3;
#pragma omp target teams distribute parallel for schedule(                     \
    static, 1) num_teams(num_teams) thread_limit(nthread)                      \
        map(to : data0[0 : dat0size],                                          \
                       data1[0 : dat1size], data2[0 : dat2size])               \
                           map(tofrom : arg3_l) reduction(+ : arg3_l)
  for ( int n_op=0; n_op<count; n_op++ ){
    //variable mapping
    double *phim = &data0[1*n_op];
    double *res = &data1[1*n_op];
    const double *u = &data2[1*n_op];
    double *rms = &arg3_l;

    //inline function
    
    *phim -= *u;
    *res = 0.0;
    *rms += (*u) * (*u);
    //end inline func
  }

  *arg3 = arg3_l;
}