%
% OP2 source code transformation tool
%
% This tool parses the user's original source code to produce
% target-specific code to execute the user's kernel functions.
%
% This prototype is written in MATLAB but a future version may
% use Python to avoid licensing costs.  Alternatively, the
% MATLAB processor can be "compiled" to produce a standalone
% version which can be freely distributed.
%
% usage: op2('file1','file2',...)
%
% This FORTRAN version takes as input
%
% file1.f90, file2.f90, ...
%
% and produces as output modified versions
%
% file1_op.f90, file2_op.f90, ...
%
% then calls a number of target-specific code generators
% to produce individual kernel files of the form
%
% xxx_kernel.f90  -- for OpenMP x86 execution
% xxx_kernel.cu   -- for CUDA execution
%
% plus a master kernel file of the form
%
% file1_kernels.f90  -- for OpenMP x86 execution
% file1_kernels.cu   -- for CUDA execution
%

function op2_fortran(varargin)

%
% declare constants
%

OP_ID   = 1;  OP_GBL   = 2;  OP_MAP = 3;

OP_READ = 1;  OP_WRITE = 2;  OP_RW  = 3;
OP_INC  = 4;  OP_MAX   = 5;  OP_MIN = 6;

OP_accs_labels = { 'OP_READ' 'OP_WRITE' 'OP_RW' ...
                   'OP_INC'  'OP_MAX'   'OP_MIN' };

date = datestr(now);

ninit = 0;
nexit = 0;
npart = 0;
nhdf5 = 0;

nconsts  = 0;
nkernels = 0;

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
%  loop over all input source files
%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

for narg = 1: nargin
  filename = varargin{narg};
  disp(sprintf('\n processing file %d of %d (%s)',...
               narg,nargin,[filename '.f90']));

  src_file = fileread([filename '.f90']);

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
% check for op_init/op_exit/op_partition/op_hdf5 calls
%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

  [inits, exits, parts, hdf5s] = op_parse_calls(src_file);

  if (inits+exits+parts+hdf5s>0)
    disp(' ');
  end
  if (inits>0)
    disp('  contains op_init call');
  end
  if (exits>0)
    disp('  contains op_exit call');
  end
  if (parts>0)
    disp('  contains op_partition call');
  end
  if (hdf5s>0)
    disp('  contains op_hdf5 calls');
  end

  ninit = ninit + inits;
  nexit = nexit + exits;
  npart = npart + parts;
  nhdf5 = nhdf5 + hdf5s;

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
% parse and process constants
%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

  const_args = op_decl_const_parse(src_file);

  for const_index = 1:length(const_args)
    name = const_args{const_index}.name;
    if (name(1)=='&')
      name = name(2:end);
      const_args{const_index}.name = name;
    end

    type = const_args{const_index}.type(2:end-1);

    [dim,ok] = str2num(const_args{const_index}.dim);
    if (ok==0)
      dim = -999;
    end

%
% check for repeats
%
    repeat = 0;
    for c = 1:nconsts
      if (strcmp(name,consts{c}.name))
        repeat = 1;
        if (~strcmp(type,consts{c}.type))
          error(sprintf('type mismatch in repeated op_decl_const'));
        end
        if (dim ~= consts{c}.dim)
          error(sprintf('size mismatch in repeated op_decl_const'));
        end
      end
    end

    if (repeat)
      disp(sprintf('\n  repeated global constant (%s)',name));

    else
      disp(sprintf('\n  global constant (%s) of size %s and type %s',...
		   name,const_args{const_index}.dim, ...
                        const_args{const_index}.type));
    end

%
% store away in master list
%
    if (~repeat)
      nconsts = nconsts + 1;

      consts{nconsts}.name = name;
      consts{nconsts}.type = type;
      consts{nconsts}.dim  = dim;
    end

  end  % end of loop over consts


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
% parse and process op_par_loop calls
%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

  loop_args = op_par_loop_parse(src_file);

  for loop_index = 1:length(loop_args)
    name  = loop_args{loop_index}.name1;
    nargs = loop_args{loop_index}.nargs;
    disp(sprintf('\n  processing kernel %s with %d arguments',...
                 name,nargs));

    if 0  % comment out all of the processing for
      disp ('  skipping processing of arguments for now')
      loop_args{loop_index}.args
    else

%
% process arguments
%

    vars = {};
    idxs = zeros(1,nargs);
    dims = {};
    maps = zeros(1,nargs);
    typs = {};
    accs = zeros(1,nargs);

    for m = 1:nargs
      type = loop_args{loop_index}.type{m};
      args = args_parse(loop_args{loop_index}.args{m});

      if (strcmp(type,'op_arg_dat'))
        vars{m} = args{1};
        idxs(m) = str2num(args{2});

	if (strcmp(args{3},'OP_ID'))
          maps(m) = OP_ID;
          if(idxs(m)~=-1)
            error(sprintf('invalid index for argument %d',m));
          end
        else
          maps(m) = OP_MAP;
          if(idxs(m)<0)
            error(sprintf('invalid index for argument %d',m));
          end
        end

        dims{m} = args{4};
        typs{m} = args{5}(2:end-1);

        if(isempty(strmatch(args{6},OP_accs_labels)))
          error(sprintf('unknown access type for argument %d',m));
        else
          accs(m) = strmatch(args{6},OP_accs_labels);
        end
      end

      if (strcmp(type,'op_arg_gbl'))
        maps(m) = OP_GBL;
        vars{m} = args{1};
        dims{m} = args{2};
        typs{m} = args{3}(2:end-1);

        if(isempty(strmatch(args{4},OP_accs_labels)))
          error(sprintf('unknown access type for argument %d',m));
        else
          accs(m) = strmatch(args{4},OP_accs_labels);
        end
      end

      if(maps(m)==OP_GBL & (accs(m)==OP_WRITE | accs(m)==OP_RW))
        error(sprintf('invalid access type for argument %d',m));
      end

      if(maps(m)~=OP_GBL & (accs(m)==OP_MIN | accs(m)==OP_MAX))
        error(sprintf('invalid access type for argument %d',m));
      end

    end

%
%  identify indirect datasets
%

    ninds     = 0;
    inds      = zeros(1,nargs);
    invinds   = zeros(1,nargs);
    indtyps   = cell(1,nargs);
    inddims   = cell(1,nargs);
    indaccs   = zeros(1,nargs);

    j = find(maps==OP_MAP);               % find all indirect arguments

    while (~isempty(j))
      match = strcmp(vars(j(1)),   vars(j)) ...  % same variable name
            & strcmp(typs(j(1)),   typs(j)) ...  % same type
            &       (accs(j(1)) == accs(j));     % same access
      ninds = ninds + 1;
      indtyps{ninds} = typs{j(1)};
      inddims{ninds} = dims{j(1)};
      indaccs(ninds) = accs(j(1));
      inds(j(find(match))) = ninds;
      invinds(ninds) = j(1);
      j = j(find(~match));          % find remaining indirect arguments
    end

%
% check for repeats
%
    repeat = 0;

    for nk = 1:nkernels
      rep1 = strcmp(kernels{nk}.name,  name ) && ...
                   (kernels{nk}.nargs==nargs) && ...
                   (kernels{nk}.ninds==ninds);
      if (rep1)
        rep2 = 1;
        for arg = 1:nargs
          rep2 = rep2 && ...
             strcmp(kernels{nk}.dims(arg),      dims(arg)) && ...
                   (kernels{nk}.maps(arg)    == maps(arg)) && ...
             strcmp(kernels{nk}.vars{arg},      vars{arg}) && ...
             strcmp(kernels{nk}.typs{arg},      typs{arg}) && ...
                   (kernels{nk}.accs(arg)    == accs(arg)) && ...
                   (kernels{nk}.idxs(arg)    == idxs(arg)) && ...
                   (kernels{nk}.inds(arg)    == inds(arg));
        end

        for arg = 1:ninds
          rep2 = rep2 && ...
             strcmp(kernels{nk}.inddims{arg},   inddims{arg}) && ...
                   (kernels{nk}.indaccs(arg) == indaccs(arg)) && ...
             strcmp(kernels{nk}.indtyps{arg},   indtyps{arg}) && ...
                   (kernels{nk}.invinds(arg) == invinds(arg));
        end

        if (rep2)
          disp('  repeated kernel with compatible arguments');
          repeat = 1;
        else
          error('  repeated kernel with incompatible arguments');
        end
      end
    end

%
% output various diagnostics
%
    if (~repeat)
      disp(['    local constants:    ' ...
            num2str(find(maps==OP_GBL & accs==OP_READ)-1) ]);
      disp(['    global reductions:  ' ...
            num2str(find(maps==OP_GBL & accs~=OP_READ)-1) ]);
      disp(['    direct arguments:   ' num2str(find(maps==OP_ID)-1) ]);
      disp(['    indirect arguments: ' num2str(find(maps==OP_MAP)-1) ]);
      if (ninds>0)
        disp(['    number of indirect datasets: ' num2str(ninds) ]);
      end
    end
%
% store away in master list
%
    if (~repeat)
      nkernels = nkernels+1;

      kernels{nkernels}.name  = name;

      kernels{nkernels}.nargs = nargs;
      kernels{nkernels}.dims  = dims;
      kernels{nkernels}.maps  = maps;
      kernels{nkernels}.vars  = vars;
      kernels{nkernels}.typs  = typs;
      kernels{nkernels}.accs  = accs;
      kernels{nkernels}.idxs  = idxs;
      kernels{nkernels}.inds  = inds;

      kernels{nkernels}.ninds   = ninds;
      kernels{nkernels}.inddims = inddims;
      kernels{nkernels}.indaccs = indaccs;
      kernels{nkernels}.indtyps = indtyps;
      kernels{nkernels}.invinds = invinds;
    end
    end
  end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
%  output new source file
%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

  fid = fopen(strcat(filename,'_op.f90'),'wt');
  fprintf(fid,'// \n// auto-generated by op2.m on %s \n//\n\n',date);

  loc_old = 1;

  loc_header = strfind(src_file,'"op_seq.h"');
  n_consts  = length(const_args);
  loc_consts = [];
  for n = 1:n_consts
    loc_consts(n) = const_args{n}.loc;
  end

  n_loops    = length(loop_args);
  loc_loops  = [];
  for n = 1:n_loops
    loc_loops(n) = loop_args{n}.loc;
  end

  locs = sort([ loc_header loc_loops loc_consts]);

%
% process header, loops and constants
%

  for loc = locs
    fprintf(fid,'%s',src_file(loc_old:loc-1));
    loc_old = loc-1;

    if (~isempty(find(loc==loc_header)))
      fprintf(fid,'"op_lib.h"\n\n');
      fprintf(fid,'//\n// op_par_loop declarations\n//\n');

      for k=1:nkernels
        fprintf(fid,'\nvoid op_par_loop_%s(char const *, op_set,\n',...
                loop_args{k}.name1);
        for n = 1:loop_args{k}.nargs-1
          fprintf(fid,'  op_arg,\n');
        end
        fprintf(fid,'  op_arg );\n');
      end

      loc_old = loc+11;
    end

    if (~isempty(find(loc==loc_loops)))
      name = loop_args{find(loc==loc_loops)}.name1;
      while (src_file(loc)~=',' || ~active(src_file(loc_old:loc)))
        loc = loc+1;
      end
      fprintf(fid,'_%s(',name);
      loc_old = loc+1;
    end

    if (~isempty(find(loc==loc_consts)))
      name = const_args{find(loc==loc_consts)}.name;
      while (src_file(loc)~='(' || ~active(src_file(loc_old:loc)))
        loc = loc+1;
      end
      fprintf(fid,'2("%s",',name);
      loc_old = loc+1;
    end
  end

  fprintf(fid,'%s',src_file(loc_old:end));

  fclose(fid);

end  % end of loop over input source files


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
%  errors and warnings
%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

if (ninit==0)
  disp(' ');
  disp('-----------------------------');
  disp('  ERROR: no call to op_init  ');
  disp('-----------------------------');
end
if (nexit==0)
  disp(' ');
  disp('-------------------------------');
  disp('  WARNING: no call to op_exit  ');
  disp('-------------------------------');
end
if (npart==0 && nhdf5>0)
  disp(' ');
  disp('---------------------------------------------------');
  disp('  WARNING: hdf5 calls without call to op_partition ');
  disp('---------------------------------------------------');
end


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
%  finally, generate target-specific kernel files
%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

op2_gen_openmp(varargin{1},date,consts,kernels)

%op2_gen_cuda(varargin{1},date,consts,kernels)

% end of main function op2()



%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
% parsing for op_init/op_exit/op_partition/op_hdf5 calls
%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

function [inits, exits, parts, hdf5s] = op_parse_calls(file)

inits = 0;
locs  = strfind(file,'op_init');

for n = 1:length(locs)
  loc = locs(n);
  if active(file(1:loc))
    inits = inits+1;
  end
end

exits = 0;
locs  = strfind(file,'op_exit');

for n = 1:length(locs)
  loc = locs(n);
  if active(file(1:loc))
    exits = exits+1;
  end
end

parts = 0;
locs  = strfind(file,'op_partition');

for n = 1:length(locs)
  loc = locs(n);
  if active(file(1:loc))
    parts = parts+1;
  end
end

hdf5s = 0;
locs  = strfind(file,'hdf5');

for n = 1:length(locs)
  loc = locs(n);
  if active(file(1:loc))
    hdf5s = hdf5s+1;
  end
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
% parsing for op_decl_const calls
%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

function consts = op_decl_const_parse(file)

consts = [];

locs = strfind(file,'op_decl_const');

for n = 1:length(locs)
  loc = locs(n);
  if active(file(1:loc))
    loc = loc + length('op_decl_const');
    args_str = active_compress(file(loc:end));

    try
      args = args_parse(args_str);
      consts{n}.loc  = loc;
      consts{n}.dim  = args{2};
      consts{n}.type = args{3};
      consts{n}.name = args{1};
    catch
      error(sprintf('error parsing op_decl_const'));
    end
  end
end


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
% parsing for op_par_loop calls
%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

function loop_args = op_par_loop_parse(file)

loop_args = [];

locs = strfind(file,'op_par_loop');

for n = 1:length(locs)
  loc = locs(n);
  if active(file(1:loc))
    loc = loc + length('op_par_loop');
    args_str = active_compress(file(loc:end));

    try
%
% NOTE: Carlo's FORTRAN API has one fewer arguments than C++ API
%
      prefix = args_str(1:strfind(args_str,'(')-1);
      args   = args_parse(args_str(1+length(prefix):end));
      loop_args{n}.loc   = loc;
      loop_args{n}.name1 = args{1};
      loop_args{n}.name2 = args{1};
      loop_args{n}.set   = args{2};
      loop_args{n}.nargs = length(args)-2;
      for m = 1:length(args)-2
        if     strcmp(args{m+2}(1:10),'op_arg_dat')
          loop_args{n}.type{m} = 'op_arg_dat';
        elseif strcmp(args{m+2}(1:10),'op_arg_gbl')
          loop_args{n}.type{m} = 'op_arg_gbl';
        end
        loop_args{n}.args{m} = args{m+2}(11:end);
      end
    catch
      error(sprintf('error parsing op_par_loop'));
    end
  end
end


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
% parse a single set of arguments
%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

function args = args_parse(string)

if ~strcmp(string(1),'(')
  error
end

loc1 = 2;
loc2 = 1;
depth = 0;
nargs = 0;

while 1
  switch string(loc2)
    case '"'
      loc2 = loc2 + 1;
      while ~strcmp(string(loc2),'"')
        loc2 = loc2 + 1;
      end
    case '('
      depth = depth + 1;
    case ')'
      depth = depth - 1;
      if (depth==0)
        nargs = nargs + 1;
        args{nargs} = string(loc1:loc2-1);
        return
      end
    case ','
      if (depth==1)
        nargs = nargs + 1;
        args{nargs} = string(loc1:loc2-1);
        loc1 = loc2 + 1;
      end
  end
  loc2 = loc2+1;
end

nargs


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
% check if the last character in a F90 file is active,
% i.e. not commented out
%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

function ans = active(file)

active_list = active_find(file);
ans = (active_list(end) == length(file));

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
% compress a F90 file, removing the comments
%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

function ans = active_compress(file)

active_list = active_find(file);
ans = [];
for m = 1:size(active_list,2)
  ans = [ ans file(active_list(1,m):active_list(2,m)) ];
end

ans = regexprep(ans,'\s','');

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
% routine to determine the active parts of a F90 file,
% i.e. the parts which are not commented out
%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

function active_list = active_find(file)

len = length(file);

loc1 = [ strfind(file,'&') len+1 ];
loc2 = [ strfind(file,'!') len+1 ];
loc4 = [ strfind(file,sprintf('\n')) len+1 ];

start = 1;

active_list = [];

while (start<=len)
  next = min(loc1(1),loc2(1));

% ignore cases embedded within a text string
  if (next<=len)
    while (mod( length(strfind(file(start:next),'"')), 2)==1)
      loc1 = loc1(find(loc1>next));
      loc2 = loc2(find(loc2>next));
      next = min(loc1(1),loc2(1));
    end
  end

  if (next>start)
    active_list = [ active_list [start; next-1] ];
  end

  if (next==loc1(1))
    %  & terminated by &
    start = loc1(min(find(loc1>next))) + 1;
  else
    %  // terminated by newline
    start = loc4(min(find(loc4>next))) + 1;
  end

  loc1 = loc1(find(loc1>=start));
  loc2 = loc2(find(loc2>=start));
end