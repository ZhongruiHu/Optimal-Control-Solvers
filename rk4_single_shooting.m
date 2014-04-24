function soln = rk4_single_shooting(prob, x0, tspan, varargin)

% -----------------------------------
% Initialize and setup options
% -----------------------------------
nSTATES = length(x0);
nSTEPS = length(tspan) - 1;
STATE_SHAPE = [nSTATES, nSTEPS+1];
h = tspan(2) - tspan(1); %TODO raise exception if ~all(diff(tspan) == 0)
nCONTROLS = size(prob.ControlBounds, 1);
CONTROL_SHAPE = [nCONTROLS, nSTEPS+1];

if isfield(prob, 'MinMax')
   MinMax = prob.MinMax;
else
   MinMax = 'Min';
end

% u0 defaults to max(0, uMin)
u0Default = max(zeros(nCONTROLS, 1), prob.ControlBounds(:,1))*...
            ones(1, nSTEPS+1); 

p = inputParser;
p.addParamValue('u0', u0Default);
p.addParamValue('TolX', 1e-6);
p.addParamValue('TolFun', 1e-4);
p.addParamValue('Algorithm', 'sqp');
p.addParamValue('Reporting', true);
parse(p, varargin{:});

u0 = p.Results.u0;
if isa(u0, 'function_handle') %if u0 is a function, eval at tspan to get vector
   u0 = u0(tspan);
end

% Turn control values into column vector for fmincon
v0 = reshape(u0, [], 1);

TolX = p.Results.TolX;
TolFun = p.Results.TolFun;
Algorithm = p.Results.Algorithm;

if p.Results.Reporting
   plotfun = @plot_func;
   iter_detail = 'iter-detailed';
else
   plotfun = [];
   iter_detail = 'off';
end


% Build nlp options structures
nlpOptions = optimset('Algorithm', Algorithm, ...
                      'GradObj', 'on', ...
                      'TolX', TolX, ...
                      'TolFun', TolFun, ...
                      'Display', iter_detail, ...
                      'PlotFcn', plotfun);


% -----------------------------------
% Main execution
% -----------------------------------

[Lb, Ub] = build_optimization_bounds();
[vOpt, soln.J] = fmincon(@nlpObjective, v0, [], [], [], [], ...
                           Lb, Ub, [], nlpOptions);
                        
if strcmp(MinMax, 'Max')
  soln.J = -soln.J;
end

soln.u = build_control(vOpt);
[soln.x, soln.lam] = compute_x_lam(prob, x0, [T0, TF], soln.u);


% -----------------------------------
% Auxillary functions
% -----------------------------------
   
   function [J, dJdu] = nlpObjective(v)
      u = reshape(v, CONTROL_SHAPE);
      [x, J] = compute_states(u, true);
      [~, dJdu] = compute_adjoints_and_grad(x, u, true);    
   end


   function [Lb, Ub] = build_optimization_bounds()
      Lb = prob.ControlBounds(:,1)*ones(1, nCONTROL_PTS);
      Ub = prob.ControlBounds(:,2)*ones(1, nCONTROL_PTS);
      Lb = reshape(Lb, [], 1);
      Ub = reshape(Ub, [], 1);
   end


   function control_func = build_control(v)
      u = reshape(v, CONTROL_SHAPE);
      control_func = vectorInterpolant(tspan, u, 'linear');
   end


   function midPts = compute_midpoints(vec)
      midPts = .5*(vec(:,1:end-1) + vec(:,2:end));
   end


   function [x, J] = compute_states(u)
      x = nan([STATE_SHAPE, 4]); % store x, xk1, xk2, and xk3 at each time pt
      x(:,1,1) = x0;
      J = 0;

      tHalf = compute_midpoints(t);
      uHalf = compute_midpoints(u);

      for i = 1:nSteps
         % Perform single RK-4 Step
         % f1, f2, f3, f4 refer to the RK approx values of the state rhs
         
         f1 = prob.stateRHS(tspan(i), x(:,i,1), u(:,i));
         x(:,i,2) = x(:,i,1) + .5*h*f1;

         f2 = prob.stateRHS(tHalf(i), x(:,i,2), uHalf(:,i));
         x(:,i,3) = x(:,i,1) + .5*h*f2;
         
         f3 = prob.stateRHS(tHalf(i), x(:,i,3), uHalf(:,i));
         x(:,i,4) = x(:,i,1) + h*f3;
         
         f4 = prob.stateRHS(tspan(i+1), x(:,i,4), u(:,i+1));
         
         x(:,i+1,1) = x(:,i,1) + h*(f1 + 2*f2 + 2*f3 + f4)/6;         
      end         
      
      % Compute objective if it is requested (vectorized)
      if nargout > 1
         g1 = prob.objective(tspan(1:end-1), x(:,1:end-1,1), u(:,1:end-1));
         g2 = prob.objective(tHalf, x(:,1:end-1,2), uHalf);
         g3 = prob.objective(tHalf, x(:,1:end-1,3), uHalf);
         g4 = prob.objective(tspan(2:end), x(:,1:end-1,4), u(:,2:end));
         J =  h*sum(g1 + 2*g2 + 2*g3 + g4)/6;
      end
   end


   function [lam, dJdu] = compute_adjoints(x, u, isComputeGrad)
      
      % store lam, lamk1, lamk2 lamk3 at each time pt
      lam = nan(STATE_SHAPE); 
      lam(:,end) = 0;

      tHalf = compute_midpoints(tspan);
      uHalf = compute_midpoints(u);

      for i = nSteps:-1:1
         dk1dx = -prob.adjointRHS(t(i), x(:,i,1), u(:,i));
         dk2dx = -prob.adjointRHS(tHalf(i), x(:,i,2), uHalf(i))*...
                     (eye(nSTATES) + .5*h*dk1dx);
         dk3dx = -prob.adjointRHS(tHalf(i), x(:,i,3), uHalf(i));
         dk4dx = -prob.adjointRHS(t(i+1), x(:,i,4), u(:,i+1));
         lam(:,i) = lam(:,i+1) + h*(dk1dx + 2*dk2dx + 2*dk3dx + dk4dx)/6;
      end
   end


   function stop = plot_func(v, optimValues, state)
      % This provides a graphical view of the progress of the NLP solver.
      % It also allows the user to stop the solver and recover the data
      % from the last iteration (as opposed to ctrl-C which will terminate
      % without returning any information)
      
      stop = 0;
      uValues = reshape(v(1:nCONTROLS*nCONTROL_PTS), nCONTROLS, []);
      if strcmp(MinMax, 'Max')
         objValue = -optimValues.fval;
      else
         objValue = optimValues.fval;
      end
      
      switch state
         case 'iter'
            if optimValues.iteration == 0
               title(sprintf('Objective Value: %1.6e', objValue))
               set(gca, 'XLim', [T0 TF], 'YLim', ...
                  [min(prob.ControlBounds(:,1)), max(prob.ControlBounds(:,2))]);
               graphHandles = plot(controlPtArray, uValues);
               set(graphHandles, 'Tag', 'handlesTag');
            else
               graphHandles = findobj(get(gca,'Children'),'Tag','handlesTag');
               graphHandles = graphHandles(end:-1:1); %Handle order gets reversed using findobj
               title(sprintf('Objective Value: %1.6e', objValue));
               for idx = 1:nCONTROLS
                  set(graphHandles(idx), 'YData', uValues(idx, :));
               end
            end
      end
   end


end

