import numpy as np
cimport numpy as np
cimport cpython
#from cython.parallel import prange
DTYPE   = np.float
ctypedef np.float_t DTYPE_t
from numpy.math cimport INFINITY

cdef extern from "math.h":
    double log(double x) nogil
    double exp(double x) nogil

from libc.stdlib cimport rand, RAND_MAX


cdef class stochastic_integration:
    cdef:
        readonly int N, M,
        int k_tot
        np.ndarray RM, rp, weights, FM, CM

    cdef calculate_total_reaction_rate(self):
        cdef:
            double W = 0. # total rate for next reaction to happen
            double [:,:] RM = self.RM
            double [:] weights = self.weights
            int M = self.M
            int i, j, k, k_tot = self.k_tot
        for i in range(M):
            for j in range(k_tot):
                for k in range(k_tot):
                    W += RM[i+j*M,i+k*M]
                    weights[i*k_tot*k_tot + k_tot*j + k] = RM[i+j*M,i+k*M]
        return W

    cdef rate_matrix(self, rp, tt):
        return

    cdef SSA_step(self,double time,
                      double total_rate):
        cdef:
            double [:] weights = self.weights
            long [:] rp = self.rp
            double dt, cs, t
            int M = self.M
            int I, i, j, k,  k_tot = self.k_tot
            int max_index = k_tot*k_tot*M,
            double fRAND_MAX = float(RAND_MAX) + 1
        # draw exponentially distributed time for next reaction
        random = rand()/fRAND_MAX
        dt = -log(random) / total_rate
        t = time + dt

        # decide which reaction happens
        random = ( rand()/fRAND_MAX ) * total_rate
        cs = 0.0
        I = 0
        while cs < random and I < max_index:
            cs += weights[I]
            I += 1
        I -= 1

        # adjust population according to chosen reaction
        i = I//( k_tot*k_tot )
        j = (I - i*k_tot*k_tot)//k_tot
        k = (I - i*k_tot*k_tot)%k_tot
        if j == k:
            rp[i + M*j] -= 1
        else:
            rp[i + M*j] += 1
            rp[i + M*k] -= 1
        return t




    cpdef simulate_gillespie(self, contactMatrix, Tf, Nf,seedRate=None):
        cdef:
            int M=self.M
            int i, j, k, I, k_tot = self.k_tot
            int max_index =  k_tot*k_tot*M*M
            double t, dt, W
            double [:,:] RM = self.RM
            long [:] rp = self.rp
            double [:] weights = self.weights
            #double [:,:] CM = self.CM

        t = 0
        if Nf <= 0:
            t_arr = []
            trajectory = []
            trajectory.append([ self.rp[j*M:(j+1)*M] for j in range(k_tot-1) ] )
        else:
            t_arr = np.arange(0,int(Tf)+1,dtype=int)
            trajectory = np.zeros([Tf+1,k_tot*M],dtype=long)
            trajectory[0] = rp
            next_writeout = 1

        while t < Tf:
            # stop if nobody is infected
            W = 0 # number of infected people
            for i in range(M,k_tot*M):
                W += rp[i]
            if W < 0.5: # if this holds, nobody is infected
                if Nf > 0:
                    for i in range(next_writeout,int(Tf)+1):
                        trajectory[i] = rp
                break

            if None != seedRate :
                self.FM = seedRate(t)
            else :
                self.FM = np.zeros( self.M, dtype = DTYPE)

            # calculate current rate matrix
            self.CM = contactMatrix(t)
            self.rate_matrix(rp, t)

            # calculate total rate
            W = self.calculate_total_reaction_rate()

            # if total reaction rate is zero
            if W == 0.:
                if Nf > 0:
                    for i in range(next_writeout,int(Tf)+1):
                        trajectory[i] = rp
                break

            # perform SSA step
            t = self.SSA_step(t,W)

            if Nf <= 0:
                t_arr.append(t)
                trajectory.append([ self.rp[j*M:(j+1)*M] for j in range(k_tot-1) ] )
            else:
                while (next_writeout < t):
                    if next_writeout > Tf:
                        break
                    trajectory[next_writeout] = rp
                    next_writeout += 1

        out_arr = np.array(trajectory,dtype=long)
        t_arr = np.array(t_arr)
        return t_arr, out_arr





    cpdef simulate_tau_leaping(self, contactMatrix, Tf, Nf,
                          int nc = 30, double epsilon = 0.03,
                          int tau_update_frequency = 1,
                          seedRate=None):
        cdef:
            int M=self.M
            int i, j, k,  I, K_events, k_tot = self.k_tot
            double t, dt, W
            double [:,:] RM = self.RM
            long [:] rp = self.rp
            double [:] weights = self.weights
            double factor, cur_f
            double cur_tau
            int SSA_steps_left = 0
            int steps_until_tau_update = 0
            double verbose = 1.

        t = 0

        if Nf <= 0:
            t_arr = []
            trajectory = []
            trajectory.append([ self.rp[j*M:(j+1)*M] for j in range(k_tot-1) ] )
        else:
            t_arr = np.arange(0,int(Tf)+1,dtype=int)
            trajectory = np.zeros([Tf+1,k_tot*M],dtype=long)
            trajectory[0] = rp
            next_writeout = 1


        while t < Tf:
            # stop if nobody is infected
            W = 0 # number of infected people
            for i in range(M,k_tot*M):
                W += rp[i]
            if W < 0.5: # if this holds, nobody is infected
                if Nf > 0:
                    for i in range(next_writeout,int(Tf)+1):
                        trajectory[i] = rp
                break

            if None != seedRate :
                self.FM = seedRate(t)
            else :
                self.FM = np.zeros( self.M, dtype = DTYPE)

            # calculate current rate matrix
            self.CM = contactMatrix(t)
            self.rate_matrix(rp, t)

            # Calculate total rate
            W = self.calculate_total_reaction_rate()

            # if total reaction rate is zero
            if W == 0.:
                if Nf > 0:
                    for i in range(next_writeout,int(Tf)+1):
                        trajectory[i] = rp
                break

            if SSA_steps_left < 0.5:
                # check if we are below threshold
                for i in range(3*M):
                    if rp[i] > 0:
                        if rp[i] < nc:
                            SSA_steps_left = 100
                # if we are below threshold, run while-loop again
                # and switch to direct SSA algorithm
                if SSA_steps_left > 0.5:
                    continue

                if steps_until_tau_update < 0.5:
                    # Determine current timestep
                    # This is based on Eqs. (32), (33) of
                    # https://doi.org/10.1063/1.2159468   (Ref. 1)
                    #
                    # note that a single index in the above cited paper corresponds
                    # to a tuple here. In the paper, possible reactions are enumerated
                    # with a single index, we enumerate the reactions as elements of the
                    # matrix RM.
                    #
                    # evaluate Eqs. (32), (33) of Ref. 1
                    cur_tau = INFINITY
                    # iterate over species
                    for i in range(M):     #  } The tuple (i,j) here corresponds
                        for j in range(k_tot): #  } to what is called "i" in Eqs. (32), (33)
                            cur_mu = 0.
                            cur_sig_sq = 0.
                            # current species has index I = i + j*M,
                            # and can either decay (diagonal element) or
                            # transform into J = i + k*M with k = 0,1,2 but k != j
                            for k in range(k_tot):
                                if j == k: # decay
                                    cur_mu -= RM[i + j*M, i + k*M]
                                    cur_sig_sq += RM[i + j*M, i + k*M]
                                else: # transformation
                                    cur_mu += RM[i + j*M, i + k*M]
                                    cur_mu -= RM[i + k*M, i + j*M]
                                    cur_sig_sq += RM[i + j*M, i + k*M]
                                    cur_sig_sq += RM[i + k*M, i + j*M]
                            cur_mu = abs(cur_mu)
                            #
                            factor = epsilon*rp[i+j*M]/2.
                            if factor < 1:
                                factor = 1.
                            #
                            if cur_mu != 0:
                                cur_mu = factor/cur_mu
                            else:
                                cur_mu = INFINITY
                            if cur_sig_sq != 0:
                                cur_sig_sq = factor**2/cur_sig_sq
                            else:
                                cur_sig_sq = INFINITY
                            #
                            if cur_mu < cur_sig_sq:
                                if cur_mu < cur_tau:
                                    cur_tau = cur_mu
                            else:
                                if cur_sig_sq < cur_tau:
                                    cur_tau = cur_sig_sq
                    steps_until_tau_update = tau_update_frequency
                    #
                    # if the current timestep is less than 10/W,
                    # switch to direct SSA algorithm
                    if cur_tau < 10/W:
                        SSA_steps_left = 50
                        continue

                steps_until_tau_update -= 1
                t += cur_tau

                # draw reactions for current timestep
                for i in range(M):
                    for j in range(k_tot):
                        for k in range(k_tot):
                            if RM[i+j*M,i+k*M] > 0:
                                # draw poisson variable
                                K_events = np.random.poisson(RM[i+j*M,i+k*M] * cur_tau )
                                if j == k:
                                    rp[i + M*j] -= K_events
                                else:
                                    rp[i + M*j] += K_events
                                    rp[i + M*k] -= K_events

            else:
                # perform SSA step
                t = self.SSA_step(t,W)
                SSA_steps_left -= 1

            if Nf <= 0:
                t_arr.append(t)
                trajectory.append([ self.rp[j*M:(j+1)*M] for j in range(k_tot-1) ] )
            else:
                while (next_writeout < t):
                    if next_writeout > Tf:
                        break
                    trajectory[next_writeout] = rp
                    next_writeout += 1

        out_arr = np.array(trajectory,dtype=long)
        t_arr = np.array(t_arr)
        return t_arr, out_arr






cdef class SIR(stochastic_integration):
    """
    Susceptible, Infected, Recovered (SIR)
    Ia: asymptomatic
    Is: symptomatic
    """
    cdef:
        readonly double alpha, beta, gIa, gIs, fsa
        readonly np.ndarray rp0, Ni, drpdt, lld, CC

    def __init__(self, parameters, M, Ni):
        self.alpha = parameters.get('alpha')                    # fraction of asymptomatic infectives
        self.beta  = parameters.get('beta')                     # infection rate
        self.gIa   = parameters.get('gIa')                      # recovery rate of Ia
        self.gIs   = parameters.get('gIa')                      # recovery rate of Is
        self.fsa   = parameters.get('fsa')                      # the self-isolation parameter

        self.N     = np.sum(Ni)
        self.M     = M
        self.Ni    = np.zeros( self.M, dtype=DTYPE)             # # people in each age-group
        self.Ni    = Ni

        self.k_tot = 3

        self.CM    = np.zeros( (self.M, self.M), dtype=DTYPE)   # contact matrix C
        self.RM = np.zeros( [self.k_tot*self.M, self.k_tot*self.M] , dtype=DTYPE)  # rate matrix
        self.FM    = np.zeros( self.M, dtype = DTYPE)           # seed function F
        self.rp = np.zeros([self.k_tot*self.M],dtype=long) # state
        self.weights = np.zeros(self.k_tot*self.k_tot*self.M,dtype=DTYPE)



    cdef rate_matrix(self, rp, tt):
        cdef:
            int N=self.N, M=self.M, i, j
            double alpha=self.alpha, beta=self.beta, gIa=self.gIa, aa, bb
            double fsa=self.fsa, alphab=1-self.alpha,gIs=self.gIs
            long [:] S    = rp[0  :M]
            long [:] Ia   = rp[M  :2*M]
            long [:] Is   = rp[2*M:3*M]
            double [:] Ni   = self.Ni
            double [:] ld   = self.lld
            double [:,:] CM = self.CM
            double [:,:] RM = self.RM
            double [:]   FM = self.FM

        for i in range(M): #, nogil=False):
            bb=0
            for j in range(M): #, nogil=False):
                 bb += beta*(CM[i,j]*Ia[j]+fsa*CM[i,j]*Is[j])/Ni[j]
            aa = bb*S[i]
            #
            RM[i+M,i] = alpha *aa + FM[i] # rate S -> Ia
            RM[i+2*M,i] = alphab *aa # rate S -> Is
            RM[i+M,i+M] = gIa*Ia[i] # rate Ia -> R
            RM[i+2*M,i+2*M] = gIs*Is[i] # rate Is -> R
        return




    cpdef simulate(self, S0, Ia0, Is0, contactMatrix, Tf, Nf,
                method='gillespie',
                int nc=30, double epsilon = 0.03,
                int tau_update_frequency = 1,
                seedRate=None
                ):
        cdef:
            M = self.M
            long [:] rp = self.rp

        # write initial condition to rp
        for i in range(M):
            rp[i] = S0[i]
            rp[i+M] = Ia0[i]
            rp[i+2*M] = Is0[i]

        if method == 'gillespie':
            t_arr, out_arr =  self.simulate_gillespie(contactMatrix, Tf, Nf,
            seedRate=seedRate)
        else:
            t_arr, out_arr =  self.simulate_tau_leaping(contactMatrix, Tf, Nf,
                                  nc=nc,
                                  epsilon= epsilon,
                                  tau_update_frequency=tau_update_frequency,
                                  seedRate=seedRate)

        out_dict = {'X':out_arr, 't':t_arr,
                     'N':self.N, 'M':self.M,
                     'alpha':self.alpha, 'beta':self.beta,
                     'gIa':self.gIa, 'gIs':self.gIs}
        return out_dict








cdef class SIkR(stochastic_integration):
    """
    Susceptible, Infected, Recovered (SIkR)
    method of k-stages of I
    """
    cdef:
        readonly int kk
        readonly double alpha, beta, gIa, gIs, fsa, gI
        readonly np.ndarray rp0, Ni, drpdt, lld, CC, gIvec

    def __init__(self, parameters, M, Ni):
        self.alpha = parameters.get('alpha')                    # fraction of asymptomatic infectives
        self.beta  = parameters.get('beta')                     # infection rate
        self.gI    = parameters.get('gI')                      # recovery rate of I
        self.fsa   = parameters.get('fsa')                      # the self-isolation parameter

        if self.gI > 0:
            self.kk    = parameters.get('k')                 # number of stages for I
            self.gIvec = self.gI * np.ones( self.kk ,dtype=DTYPE)
        else:
            self.gIvec = parameters.get('gIvec')

        self.N     = np.sum(Ni)
        self.M     = M
        self.Ni    = np.zeros( self.M, dtype=DTYPE)             # # people in each age-group
        self.Ni    = Ni

        self.k_tot = 1 + self.kk # total number of compartments per age group,
        # namely (1 susceptible + kk infected compartments)

        self.CM    = np.zeros( (self.M, self.M), dtype=DTYPE)   # contact matrix C
        self.RM = np.zeros( [self.k_tot*self.M,self.k_tot*self.M] , dtype=DTYPE)  # rate matrix
        self.FM    = np.zeros( self.M, dtype = DTYPE)           # seed function F
        self.rp = np.zeros([self.k_tot*self.M],dtype=long) # state
        self.weights = np.zeros(self.k_tot*self.k_tot*self.M,dtype=DTYPE)



    cdef rate_matrix(self, rp, tt):
        cdef:
            int N=self.N, M=self.M, i, j, jj, kk=self.kk
            double beta=self.beta, aa, bb
            long [:] S    = rp[0  :M]
            long [:] I    = rp[M  :(kk+1)*M]
            double [:] gIvec = self.gIvec
            double [:] Ni   = self.Ni
            double [:] ld   = self.lld
            double [:,:] CM = self.CM
            double [:,:] RM = self.RM
            double [:]   FM = self.FM

        for i in range(M): #, nogil=False):
            bb=0
            for jj in range(kk):
                for j in range(M):
                    bb += beta*(CM[i,j]*I[j+jj*M])/Ni[j]
            aa = bb*S[i]
            #
            RM[i+M,i] =  aa + FM[i] # rate S -> I1
            for j in range(kk-1):
                RM[i+(j+2)*M, i + (j+1)*M]   =  kk * gIvec[j] * I[i+j*M] # rate I_{j} -> I_{j+1}
            RM[i+kk*M, i+kk*M] = kk * gIvec[kk-1] * I[i+(kk-1)*M] # rate I_{k} -> R
        return





    cpdef simulate(self, S0, I0, contactMatrix, Tf, Nf,
                method='gillespie',
                int nc=30, double epsilon = 0.03,
                int tau_update_frequency = 1,
                seedRate=None
                ):
        cdef:
            M = self.M
            kk = self.kk
            long [:] rp = self.rp

        # write initial condition to rp
        for i in range(M):
            rp[i] = S0[i]
            for j in range(kk):
              rp[i+(j+1)*M] = I0[j]

        if method == 'gillespie':
            t_arr, out_arr =  self.simulate_gillespie(contactMatrix, Tf, Nf,
                                    seedRate=seedRate)
        else:
            t_arr, out_arr =  self.simulate_tau_leaping(contactMatrix, Tf, Nf,
                                  nc=nc,
                                  epsilon= epsilon,
                                  tau_update_frequency=tau_update_frequency,
                                      seedRate=seedRate)

        out_dict = {'X':out_arr, 't':t_arr,
                      'N':self.N, 'M':self.M,
                      'alpha':self.alpha, 'beta':self.beta,
                      'gI':self.gI, 'k':self.kk }
        return out_dict






cdef class SEIR(stochastic_integration):
    """
    Susceptible, Exposed, Infected, Recovered (SEIR)
    Ia: asymptomatic
    Is: symptomatic
    """
    cdef:
        readonly double alpha, beta, fsa, gIa, gIs, gE
        readonly np.ndarray rp0, Ni, drpdt, lld, CC

    def __init__(self, parameters, M, Ni):
        self.alpha = parameters.get('alpha')                    # fraction of asymptomatic infectives
        self.beta  = parameters.get('beta')                     # infection rate
        self.gIa   = parameters.get('gIa')                      # recovery rate of Ia
        self.gIs   = parameters.get('gIs')                      # recovery rate of Is
        self.gE    = parameters.get('gE')                       # recovery rate of E
        self.fsa   = parameters.get('fsa')                      # the self-isolation parameter

        self.N     = np.sum(Ni)
        self.M     = M
        self.Ni    = np.zeros( self.M, dtype=DTYPE)             # # people in each age-group
        self.Ni    = Ni

        self.k_tot = 4

        self.CM    = np.zeros( (self.M, self.M), dtype=DTYPE)   # contact matrix C
        self.RM = np.zeros( [self.k_tot*self.M,self.k_tot*self.M] , dtype=DTYPE)  # rate matrix
        self.FM    = np.zeros( self.M, dtype = DTYPE)           # seed function F
        self.rp = np.zeros([self.k_tot*self.M],dtype=long) # state
        self.weights = np.zeros(self.k_tot*self.k_tot*self.M,dtype=DTYPE)



    cdef rate_matrix(self, rp, tt):
        cdef:
            int N=self.N, M=self.M, i, j
            double gIa=self.gIa, gIs=self.gIs
            double gE=self.gE, ce1=self.gE*self.alpha, ce2=self.gE*(1-self.alpha)
            double beta=self.beta, aa, bb
            double fsa = self.fsa
            long [:] S    = rp[0  :  M]
            long [:] E    = rp[  M:2*M]
            long [:] Ia   = rp[2*M:3*M]
            long [:] Is   = rp[3*M:4*M]
            double [:] Ni   = self.Ni
            double [:,:] CM = self.CM
            double [:,:] RM = self.RM
            double [:]   FM = self.FM

        for i in range(M): #, nogil=False):
            bb=0
            for j in range(M):
                 bb += beta*CM[i,j]*(Ia[j]+fsa*Is[j])/Ni[j]
            aa = bb*S[i]
            #
            RM[i+M  , i]     =  aa + FM[i] # rate S -> E
            RM[i+2*M, i+M]   = ce1 * E[i] # rate E -> Ia
            RM[i+3*M, i+M]   = ce2 * E[i] # rate E -> Is
            RM[i+2*M, i+2*M] = gIa * Ia[i] # rate Ia -> R
            RM[i+3*M, i+3*M] = gIs * Is[i] # rate Is -> R
        return


    cpdef simulate(self, S0, E0, Ia0, Is0, contactMatrix, Tf, Nf,
                method='gillespie',
                int nc=30, double epsilon = 0.03,
                int tau_update_frequency = 1,
                seedRate=None
                ):
        cdef:
            M = self.M
            long [:] rp = self.rp

        # write initial condition to rp
        for i in range(M):
            rp[i] = S0[i]
            rp[i+M] = E0[i]
            rp[i+2*M] = Ia0[i]
            rp[i+3*M] = Is0[i]

        if method == 'gillespie':
            t_arr, out_arr =  self.simulate_gillespie(contactMatrix, Tf, Nf,
                                    seedRate=seedRate)
        else:
            t_arr, out_arr =  self.simulate_tau_leaping(contactMatrix, Tf, Nf,
                                  nc=nc,
                                  epsilon= epsilon,
                                  tau_update_frequency=tau_update_frequency,
                                      seedRate=seedRate)

        out_dict = {'X':out_arr, 't':t_arr,
                      'N':self.N, 'M':self.M,
                      'alpha':self.alpha, 'beta':self.beta,
                      'gIa':self.gIa,'gIs':self.gIs,
                      'gE':self.gE}
        return out_dict
