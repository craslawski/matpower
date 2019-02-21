function [V, converged, i] = zgausspf(Ybus, Sbus, V0, ref, pv, pq, Bpp, mpopt)
%ZGAUSSPF  Solves the power flow using an Implicit Z-bus Gauss method.
%   [V, CONVERGED, I] = ZGAUSSPF(YBUS, SBUS, V0, REF, PV, PQ, BPP, MPOPT)
%   solves for bus voltages given the full system admittance matrix (for
%   all buses), the complex bus power injection vector (all buses),
%   the initial vector of complex bus voltages, column vectors with the
%   lists of bus indices for the swing bus, PV buses, and PQ buses,
%   respectively, and the fast-decoupled B double-prime matrix (all buses)
%   for Q updates at PV buses. The bus voltage vector contains the set point
%   for generator (including ref bus) buses, and the reference angle of the
%   swing bus, as well as an initial guess for remaining magnitudes and
%   angles. MPOPT is a MATPOWER options struct which can be used to
%   set the termination tolerance, maximum number of iterations, and
%   output options (see MPOPTION for details). Uses default options
%   if this parameter is not given. Returns the final complex voltages,
%   a flag which indicates whether it converged or not, and the number
%   of iterations performed.
%
%   NOTE: This method does not scale well with the number of generators
%       and seems to have serious problems with some systems with many
%       PV buses.
%
%   See also RUNPF.

%   MATPOWER
%   Copyright (c) 1996-2019 by Power System Engineering Research Center (PSERC)
%   by Ray Zimmerman, PSERC Cornell
%
%   This file is part of MATPOWER.
%   Covered by the 3-clause BSD License (see LICENSE file for details).
%   See http://www.pserc.cornell.edu/matpower/ for more info.

%% default arguments
if nargin < 8
    mpopt = mpoption;
end

%% options
complex = 0;    %% use 1 = complex formulation, 0 = use real formulation
pv_method = 2;  %% 0 = simple voltage magnitude reset
                %% 1 = sens real(V) to imag(I)
                %% 2 = dVm/dQ (fast-decoupled Jac)
tol     = mpopt.pf.tol;
max_it  = mpopt.pf.zg.max_it;
if have_fcn('matlab') && have_fcn('matlab', 'vnum') < 7.3
    lu_vec = 0;     %% lu(..., 'vector') syntax not supported
else
    lu_vec = 1;
end

%% initialize
converged = 0;
i = 0;
j = sqrt(-1);
V = V0;
Vm = abs(V);
npv = length(pv);
npq = length(pq);
nb = length(V);
max_dV = 0;

%% shift voltage angles if necessary
% Varef = angle(V(ref));
% if Varef ~= 0
%     V = V * exp(-j * Varef);
% end
if complex
    V1 = V(ref);
else
    V1 = [real(V(ref)); imag(V(ref))];
end

%% create sub-matrices, separating ref bus from other buses
if complex
%     Y11 = Ybus(ref,ref);
%     Y12 = Ybus(ref, [pv;pq]);
    Y21 = Ybus([pv;pq], ref);
    Y21_V1 = Y21 * V1;
    Y22 = Ybus([pv;pq], [pv;pq]);
else
    G = real(Ybus);
    B = imag(Ybus);
%     Y11 = [ G(ref,ref) -B(ref,ref);
%             B(ref,ref)  G(ref,ref) ];
%     Y12 = [ G(ref,pv) -B(ref,pv) G(ref,pq) -B(ref,pq);
%             B(ref,pv)  G(ref,pv) B(ref,pq)  G(ref,pq) ];
    Y21 = [ G(pv,ref) -B(pv,ref);
            B(pv,ref)  G(pv,ref);
            G(pq,ref) -B(pq,ref);
            B(pq,ref)  G(pq,ref) ];
    Y21_V1 = Y21 * V1;
    Y22 = [ G(pv,pv) -B(pv,pv) G(pv,pq) -B(pv,pq);
            B(pv,pv)  G(pv,pv) B(pv,pq)  G(pv,pq);
            G(pq,pv) -B(pq,pv) G(pq,pq) -B(pq,pq);
            B(pq,pv)  G(pq,pv) B(pq,pq)  G(pq,pq)  ];
end
if lu_vec
    [L, U, p, q] = lu(Y22, 'vector');
    [junk, iq] = sort(q);
else
    [L, U, P] = lu(Y22);
end

%% initialize PV bus handling
if npv
    Vmpv0 = Vm(pv);     %% voltage setpoints for PV buses

    switch pv_method
        case 1
            %% Essentially, the following, only more efficiently ...
            % Y22_inv = inv(Y22);
            % dVdI = -imag(Y22_inv(1:npv, 1:npv));      % complex
            % dVdI = Y22_inv(1:npv, npv+(1:npv));       % real
            if complex
                rhs = sparse(1:npv, 1:npv, j, npv+npq, npv);
            else
                rhs = sparse(npv+(1:npv), 1:npv, 1, 2*(npv+npq), npv);
            end
            % cols_of_Y22_inv = Y22 \ rhs;
            if lu_vec
                cols_of_Y22_inv = U \ (L \ rhs(p, :));
                cols_of_Y22_inv = cols_of_Y22_inv(iq, :);
            else
                cols_of_Y22_inv = U \ (L \ P * rhs);
            end
            if complex
                dVdI = real(cols_of_Y22_inv(1:npv, :));
            else
                dVdI = cols_of_Y22_inv(1:npv, :);
            end

            [LL, UU, PP] = lu(dVdI);    %% not sparse, so don't use 'vector' version
        case 2
            if lu_vec
                [LBpp, UBpp, pBpp, qBpp] = lu(Bpp(pq, pq), 'vector');
                [junk, iqBpp] = sort(qBpp);
            else
                [LBpp, UBpp, PBpp] = lu(Bpp(pq, pq));
            end
    end
end

%% check tolerance
if mpopt.verbose > 1
    fprintf('\n it      ∆V (p.u.)    max abs(S) mismatch (p.u.)    max V mismatch (PV) (p.u.) ');
    fprintf('\n----    -----------  ----------------------------  ----------------------------');
end

%% do implicit Zbus Gauss iterations
while (~converged && i < max_it)
    %% update iteration counter
    i = i + 1;

    %% save voltage from previous iteration
    Vp = V;

    if npv      %% update Q injections @ PV buses based on V mismatch
        if pv_method    %% 1 or 2
            %% compute Q injection at current V
            %% (sometimes improves convergence for pv_method=1,2)
            Qpv = imag( V(pv) .* conj(Ybus(pv, :) * V) );
            Sbus(pv) = Sbus(pv) + j * (Qpv - imag(Sbus(pv)));

            %% compute voltage mismatch at PV buses
            Vmpv = abs(V(pv));
            dV = Vmpv0 - Vmpv;
            [max_dV, k] = max(abs(dV));
%            dV([1:k-1 k+1:end]) = 0;   %% one at a time?

            % Two alternate approaches (that seem to work about equally well):
            %   1 - use precomputed sensitivity of real(V) to imag(I)
            %   2 - use sensitivity of Vm to Q evaluated at current V (fast-decoupled)
            switch pv_method
                case 1      %% precomputed sensitivity of real(V) to imag(I)
                    %% estimate corresponding change in imag(I) injection
                    dQ = -UU \  (LL \ (PP * dV));    %% dQ = -dI = -dVdI \ dV;
                case 2      %% sensitivity of Vm to Q evaluated at current V (fast-decoupled Jacobian)
                    % dVpq = Bpp(pq, pq) \ (-Bpp(pq, pv) * dV);
                    if lu_vec
                        dVpq = UBpp \  (LBpp \ (-Bpp(pq(pBpp), pv) * dV));
                        dVpq = dVpq(iqBpp);
                    else
                        dVpq = UBpp \  (LBpp \ (PBpp * (-Bpp(pq, pv) * dV)));
                    end
                    dQ = Bpp(pv, pq) * dVpq + Bpp(pv, pv) * dV;
            end

            %% update Sbus
            Sbus(pv) = Sbus(pv) + j * dQ;

            %% set voltage magnitude at PV buses
            %% doesn't consistently improve convergence for pv_method=1,2
%            V(pv) = V(pv) ./ abs(V(pv)) .* abs(V0(pv));
        else    %% pv_method = 0
            %% compute Q injection at current V
            %% (updating Q before V converges more consistently)
            Qpv = imag( V(pv) .* conj(Ybus(pv, :) * V) );
            Sbus(pv) = Sbus(pv) + j * (Qpv - imag(Sbus(pv)));

            %% set voltage magnitude at PV buses
            V(pv) = V(pv) ./ abs(V(pv)) .* abs(V0(pv));

%             %% compute Q injection at current V
%             Qpv = imag( V(pv) .* conj(Ybus(pv, :) * V) );
%             Sbus(pv) = Sbus(pv) + j * (Qpv - imag(Sbus(pv)));
        end
    end

    %% update currents
    Ipv = conj(Sbus(pv) ./ V(pv));
    Ipq = conj(Sbus(pq) ./ V(pq));
    if complex
        I2 = [Ipv; Ipq];
    else
        I2 = [real(Ipv); imag(Ipv); real(Ipq); imag(Ipq)];
    end
    
    %% solve for new voltages (except at ref & PV buses)
    if lu_vec
        V2 = U \  (L \ (I2(p) - Y21_V1(p)));
        V2 = V2(iq);
    else
        V2 = U \  (L \ (P * (I2 - Y21_V1)));
    end
    % V2 = Y22 \ (I2 - Y21_V1);
    if complex
        V(pv) = V2(1:npv);
        V(pq) = V2(npv+1:npv+npq);
    else
        V(pv) = V2(1:npv) + j * V2(npv+1:2*npv);
        V(pq) = V2(2*npv+1:2*npv+npq) + j * V2(2*npv+npq+1:2*npv+2*npq);
    end

    %% check for convergence
    normV = norm(V-Vp, Inf);
    normS = norm(Sbus([pv; pq]) - V([pv; pq]) .* conj([Ipv; Ipq]), Inf);
    if mpopt.verbose > 1
%        fprintf('\n%3d        %10.3e %10.6g %10.6g %10.6g %10.6g', i, normV, V(pv(1)), V(pv(2)), imag(Sbus(pv(1))), imag(Sbus(pv(2))));
%        fprintf('\n%3d        %10.3e %10.6g %10.6g', i, normV, V(pv(1)), imag(Sbus(pv(1))));
        fprintf('\n%3d     %10.3e             %10.3e                  %10.3e', i, normV, normS, max_dV);
    end
    if normV < tol
        converged = 1;
        if mpopt.verbose
            fprintf('\nImplicit Z-bus Gauss power flow converged in %d iterations.\n', i);
        end
    end
    if normV > 1    %% diverging, time to bail out
        break;
    end
end

%% shift voltage angles back if necessary
% if Varef ~= 0
%     V = V * exp(j * Varef);
% end

if mpopt.verbose
    if ~converged
        if i == max_it
            fprintf('\nImplicit Z-bus Gauss power flow did not converge in %d iterations.\n', i);
        else
            fprintf('\nImplicit Z-bus Gauss power flow diverged in %d iterations.\n', i);
        end
    end
end
