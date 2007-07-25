!
! Copyright (C) 2001-2004 PWSCF group
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!  
#include "f_defs.h"
!
!----------------------------------------------------------------------------
SUBROUTINE electrons()
  !----------------------------------------------------------------------------
  !
  ! ... This routine is a driver of the self-consistent cycle.
  ! ... It uses the routine c_bands for computing the bands at fixed
  ! ... Hamiltonian, the routine sum_bands to compute the charge
  ! ... density, the routine v_of_rho to compute the new potential
  ! ... and the routine mix_potential to mix input and output
  ! ... potentials.
  !
  ! ... It prints on output the total energy and its decomposition in
  ! ... the separate contributions.
  !
  USE kinds,                ONLY : DP
  USE parameters,           ONLY : npk 
  USE constants,            ONLY : eps8, rytoev
  USE io_global,            ONLY : stdout, ionode
  USE cell_base,            ONLY : at, bg, alat, omega, tpiba2
  USE ions_base,            ONLY : zv, nat, ntyp => nsp, ityp, tau
  USE basis,                ONLY : startingpot
  USE gvect,                ONLY : ngm, gstart, nr1, nr2, nr3, nrx1, nrx2, &
                                   nrx3, nrxx, nl, nlm, g, gg, ecutwfc, gcutm
  USE gsmooth,              ONLY : doublegrid, ngms
  USE klist,                ONLY : xk, wk, degauss, nelec, ngk, nks, nkstot, &
                                   lgauss, ngauss, two_fermi_energies, &
                                   nelup, neldw
  USE lsda_mod,             ONLY : lsda, nspin, magtot, absmag, isk
  USE ktetra,               ONLY : ltetra, ntetra, tetra  
  USE vlocal,               ONLY : strf, vnew  
  USE wvfct,                ONLY : nbnd, et, gamma_only, wg,npwx
  USE ener,                 ONLY : etot, eband, deband, ehart, vtxc, etxc, &
                                   etxcc, ewld, demet, ef, ef_up, ef_dw 
  USE scf,                  ONLY : rho, vr, vltot, vrs, rho_core
  USE control_flags,        ONLY : mixing_beta, tr2, ethr, niter, nmix,       &
                                   iprint, istep, lscf, lmd, conv_elec,       &
                                   restart, reduce_io, iverbosity
  USE io_files,             ONLY : prefix, iunwfc, iunocc, nwordwfc, iunpath, &
                                   output_drho, iunefield
  USE ldaU,                 ONLY : ns, nsnew, eth, Hubbard_U, &
                                   niter_with_fixed_ns, Hubbard_lmax, &
                                   lda_plus_u  
  USE extfield,             ONLY : tefield, etotefield  
  USE wavefunctions_module, ONLY : evc, evc_nc, psic
  USE noncollin_module,     ONLY : noncolin, npol, magtot_nc
  USE noncollin_module,     ONLY : factlist, pointlist, pointnum, mcons,&
                                   i_cons, bfield, lambda, vtcon, report
  USE spin_orb,             ONLY : domag
  USE mp_global,            ONLY : me_pool
  USE pfft,                 ONLY : npp, ncplane
  USE bp
#if defined (EXX)
  USE exx,                  ONLY : lexx, exxinit, init_h_wfc, &
                                   exxalfa, exxstart, exxenergy, exxenergy2 
  USE funct,                ONLY : dft, which_dft, iexch, icorr, igcx, igcc
#endif
  !
  !!PAW]
  USE grid_paw_variables,   ONLY : really_do_paw, okpaw, tpawp, &
       ehart1, ehart1t, etxc1, etxc1t, deband_1ae, deband_1ps,  &
       descf_1ae, descf_1ps, rho1, rho1t, rho1new, rho1tnew,  &
       vr1, vr1t, becnew
  USE grid_paw_routines,    ONLY : compute_onecenter_potentials, &
       compute_onecenter_charges, delta_e_1, delta_e_1scf
  USE rad_paw_routines !,     ONLY : sum_rad_rho, rad_potential,coc_pwned,rad_dipole  !pltz
  USE uspp,                 ONLY : becsum
  USE uspp_param,           ONLY : nhm
  !!PAW]
  !
  IMPLICIT NONE
  !
  ! ... a few local variables
  !  
#if defined (EXX)
  REAL (DP) :: dexx
  REAL (DP) :: fock0,  fock1,  fock2
#endif
  INTEGER :: &
      ngkp(npk)        !  number of plane waves summed on all nodes
  CHARACTER (LEN=256) :: &
      flmix            !
  REAL(DP) :: &
      dr2,            &!  the norm of the diffence between potential
      charge,         &!  the total charge
      mag,            &!  local magnetization
      ehomo, elumo,   &!  highest occupied and lowest onuccupied levels
      tcpu             !  cpu time
   INTEGER :: &
      i,              &!  counter on polarization
      is,             &!  counter on spins
      ig,             &!  counter on G-vectors
      ik,             &!  counter on k points
      ibnd,           &!  counter on bands
      idum,           &!  dummy counter on iterations
      iter,           &!  counter on iterations
      ik_              !  used to read ik from restart file
  INTEGER :: &
      ldim2           !
  REAL (DP) :: &
       tr2_min,      &! estimated error on energy coming from diagonalization
       descf          ! correction for variational energy

  REAL (DP), ALLOCATABLE :: &
      wg_g(:,:)        ! temporary array used to recover from pools array wg,
                       ! and then print occupations on stdout
  LOGICAL :: &
      exst, first
  !
  ! ... external functions
  !
  REAL (DP), EXTERNAL :: ewald, get_clock
  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
  COMPLEX (DP), ALLOCATABLE :: rhog(:,:)
  COMPLEX (DP), ALLOCATABLE :: rhognew(:,:)
  REAL (DP), ALLOCATABLE :: rhonew(:,:)
  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
  !!PAW[  And this for PAW  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
  REAL(DP), ALLOCATABLE :: becstep(:,:,:)
  INTEGER :: na
  REAL (DP) :: correction1c
  REAL (DP), ALLOCATABLE :: deband_1ps_na(:), deband_1ae_na(:), & ! auxiliary info on
                            descf_1ps_na(:), descf_1ae_na(:)      ! one-center corrections
  !!PAW]  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!  
 !
  ! PU added for electric field
  COMPLEX(DP), ALLOCATABLE  :: psi(:,:)
  INTEGER inberry

  !
  CALL start_clock( 'electrons' )
  IF (okpaw) ALLOCATE ( deband_1ae_na(nat), deband_1ps_na(nat), &
                        descf_1ae_na(nat),  descf_1ps_na(nat) )
  !
  iter = 0
  ik_  = 0
  !
  write (*,*) "ok 3.0"
  IF ( restart ) THEN
     !
     CALL restart_in_electrons( iter, ik_, dr2 )
     !
     IF ( ik_ == -1000 ) THEN
        !
        conv_elec = .TRUE.
        !
        IF ( output_drho /= ' ' ) CALL remove_atomic_rho
        !
        CALL stop_clock( 'electrons' )
        !
        IF (okpaw) DEALLOCATE(deband_1ae_na, deband_1ps_na, descf_1ae_na, descf_1ps_na)
        RETURN
        !
     END IF
     !
  END IF
  !
  tcpu = get_clock( 'PWSCF' )
  WRITE( stdout, 9000 ) tcpu
  !
  CALL flush_unit( stdout )
  !
  IF ( .NOT. lscf ) THEN
     !
     CALL non_scf()
     !
     IF (okpaw) DEALLOCATE(deband_1ae_na, deband_1ps_na, descf_1ae_na, descf_1ps_na)
     RETURN
     !
  END IF
  !
  ! ... calculates the ewald contribution to total energy
  !
  ewld = ewald( alat, nat, ntyp, ityp, zv, at, bg, tau, omega, &
                g, gg, ngm, gcutm, gstart, gamma_only, strf )
  !               
  IF ( reduce_io ) THEN
     !
     flmix = ' '
     !
  ELSE
     !
     flmix = 'mix'
     !
  END IF
  !
  ! ... Convergence threshold for iterative diagonalization
  !
  ! ... for the first scf iteration of each ionic step after the first,
  ! ... the threshold is fixed to a default value of 1.D-5
  !
#if defined (EXX)
10 continue
#endif

  IF ( istep > 1 ) ethr = 1.D-5
  !
  WRITE( stdout, 9001 )
  !
  CALL flush_unit( stdout )
  !
  !%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
  !%%%%%%%%%%%%%%%%%%%%          iterate !          %%%%%E mix%%%%%%%%%%%%%%%%
  !%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
  !
  IF ( .not. ALLOCATED(rhog) ) ALLOCATE (rhog(ngm, nspin))
  DO is = 1, nspin
     psic(:) = rho (:, is)
     CALL cft3 (psic, nr1, nr2, nr3, nrx1, nrx2, nrx3, -1)
     rhog(:, is) = psic ( nl(:) )
  END DO
  !!PAW[
  IF (okpaw) THEN
     IF ( .not. ALLOCATED(becstep) ) ALLOCATE (becstep(nhm*(nhm+1)/2,nat,nspin))
     becstep (:,:,:) = 0.d0
     DO na = 1, nat       
        IF (tpawp(ityp(na))) becstep(:,na,:) = becsum(:,na,:)
     END DO
  END IF
  !!PAW]
  DO idum = 1, niter
     !
     IF ( check_stop_now() ) RETURN
     !
     !  
     iter = iter + 1
     !
     WRITE( stdout, 9010 ) iter, ecutwfc, mixing_beta
     !
     CALL flush_unit( stdout )
     !
     ! ... Convergence threshold for iterative diagonalization
     ! ... is automatically updated during self consistency
     !
     IF ( iter > 1 .AND. ik_ == 0 ) THEN
        !
        IF ( iter == 2 ) ethr = 1.D-2
        !
        ethr = MAX( MIN( ethr , ( dr2 / nelec * 0.1D0 ) ) , &
                       ( tr2 / nelec * 0.01D0 ) )
        !
     END IF
     !
     first = ( iter == 1 )
     !
     scf_step: DO 
        !
        ! ... tr2_min is set to an estimate of the error on the energy
        ! ... due to diagonalization - used only in the first scf iteration
        !
        IF ( first ) THEN
           !
           tr2_min = nelec * ethr
           !
        ELSE
           !
           tr2_min = 0.D0
           !
        END IF
        !
        ! ... diagonalization of the KS hamiltonian
        !
        if(lelfield) then
          do inberry=1,nberrycic
            ALLOCATE (psi(npwx,nbnd))
            do ik=1,nks
               call davcio(psi,nwordwfc,iunwfc,ik,-1)
               call davcio(psi,nwordwfc,iunefield,ik,1)
             enddo
             DEALLOCATE( psi)
            CALL c_bands( iter, ik_, dr2 )
          enddo
        else
          CALL c_bands( iter, ik_, dr2 )
         endif
        !
        IF ( check_stop_now() ) RETURN
        !
        !!PAW : sum_band DOES NOT compute new one-center charges
        CALL sum_band()
        !
        IF ( lda_plus_u )  THEN
           !
           ldim2 = ( 2 * Hubbard_lmax + 1 )**2
           !
           CALL write_ns()
           !
           IF ( first .AND. istep == 1 .AND. &
                startingpot == 'atomic' ) CALL ns_adj()
           !
           IF ( iter <= niter_with_fixed_ns ) nsnew = ns 
           !
        END IF
        !
        ! ... calculate total and absolute magnetization
        !
        IF ( lsda .OR. noncolin ) CALL compute_magnetization()
        !
        ! ... delta_e = - int rho(r) (V_H + V_xc)(r) dr
        !
        deband = delta_e()
        ALLOCATE (rhognew(ngm, nspin))
        !!PAW[
        IF (okpaw) THEN
           CALL compute_onecenter_charges (becsum,rho1,rho1t)
           deband_1ae = delta_e_1(rho1, vr1, deband_1ae_na)  !AE
           deband_1ps = delta_e_1(rho1t,vr1t,deband_1ps_na)  !PS
           CALL infomsg ('electrons','mixing several times ns if lda_plus_U',-1)
           IF (lda_plus_U) STOP 'electrons - not implemented'
           ALLOCATE (becnew(nhm*(nhm+1)/2, nat, nspin) )
           becnew(:,:,:) = 0.d0
           DO na = 1, nat
              IF (tpawp(ityp(na))) becnew(:,na,:) = becsum(:,na,:)
           END DO
        END IF
        !!PAW]
        !
        do is = 1, nspin
           psic(:) = rho (:, is)
           call cft3 (psic, nr1, nr2, nr3, nrx1, nrx2, nrx3, - 1)
           rhognew (:, is) = psic ( nl(:) )
        end do
        !TEMP
        !
        CALL mix_rho( rhognew, rhog, becnew, becstep, nsnew, ns, mixing_beta, &
             dr2, tr2_min, iter, nmix, flmix, conv_elec )
        !
        DEALLOCATE (rhognew)
        !
        !!PAW[
        IF (okpaw) DEALLOCATE (becnew)
        !!PAW]
        !
        ! ... for the first scf iteration it is controlled that the 
        ! ... threshold is small enough for the diagonalization to 
        ! ... be adequate
        !
        IF ( first ) THEN
           !
           first = .FALSE.
           !
           IF ( dr2 < tr2_min ) THEN
              !
              ! ... a new diagonalization is needed       
              !
              WRITE( stdout, '(/,5X,"Threshold (ethr) on eigenvalues was ", &
                               &    "too large:",/,5X,                      &
                               & "Diagonalizing with lowered threshold",/)' )
              !
              ethr = dr2 / nelec
              !
              CYCLE scf_step
              !
           END IF
           !
        END IF             
        !
        IF ( .NOT. conv_elec ) THEN
           !TEMP
           ALLOCATE (rhonew (nrxx, nspin) )
           do is = 1, nspin
              psic( :) = (0.d0, 0.d0)
              psic( nl(:) ) = rhog (:, is)
              if (gamma_only) psic( nlm(:) ) = CONJG (rhog (:, is))
              call cft3 (psic, nr1, nr2, nr3, nrx1, nrx2, nrx3, +1)
              rhonew (:, is) = psic (:)
           end do
           !TEMP
           !
           ! ... no convergence yet: calculate new potential from 
           ! ... new estimate of the charge density 
           !
           CALL v_of_rho( rhonew, rho_core, nr1, nr2, nr3, nrx1, nrx2,   &
                          nrx3, nrxx, nl, ngm, gstart, nspin, g, gg, alat, &
                          omega, ehart, etxc, vtxc, etotefield, charge, vr )
           !
           !!PAW[
           !!PAW : calculates new one-center charges in R-space
           IF (okpaw) THEN

              ALLOCATE (rho1new (nrxx,nspin,nat), rho1tnew(nrxx,nspin,nat) )
#define DEBUG_PAW
#ifdef DEBUG_PAW
              ! NEW RADIAL PAW (start)
              CALL PAW_energy(becstep)  !pltz
              ! NEW RADIAL PAW (end)

              ! LM = 1
!               CALL coc_pwned (becstep, rho1new, rho1tnew,1)
!               CALL compute_onecenter_potentials(becstep,rho1new,rho1tnew,fixed_lm=1)
!               WRITE(6,"(a,4f15.7)") "==GRID PAW ENERGIES (LM=1): ", ehart1(1), ehart1(2), ehart1t(1), ehart1t(2)
!               CALL coc_pwned (becstep, rho1new, rho1tnew,2)
!               CALL compute_onecenter_potentials(becstep,rho1new,rho1tnew,fixed_lm=2)
!               WRITE(6,"(a,4f15.7)") "==GRID PAW ENERGIES (LM=2): ", ehart1(1), ehart1(2), ehart1t(1), ehart1t(2)
!               CALL coc_pwned (becstep, rho1new, rho1tnew,3)
!               CALL compute_onecenter_potentials(becstep,rho1new,rho1tnew,fixed_lm=3)
!               WRITE(6,"(a,4f15.7)") "==GRID PAW ENERGIES (LM=3): ", ehart1(1), ehart1(2), ehart1t(1), ehart1t(2)
!               CALL coc_pwned (becstep, rho1new, rho1tnew,4)
!               CALL compute_onecenter_potentials(becstep,rho1new,rho1tnew,fixed_lm=4)
!               WRITE(6,"(a,4f15.7)") "==GRID PAW ENERGIES (LM=4): ", ehart1(1), ehart1(2), ehart1t(1), ehart1t(2)
!               CALL coc_pwned (becstep, rho1new, rho1tnew,5)
!               CALL compute_onecenter_potentials(becstep,rho1new,rho1tnew,fixed_lm=5)
!               WRITE(6,"(a,4f15.7)") "==GRID PAW ENERGIES (LM=5): ", ehart1(1), ehart1(2), ehart1t(1), ehart1t(2)
!               CALL coc_pwned (becstep, rho1new, rho1tnew,6)
!               CALL compute_onecenter_potentials(becstep,rho1new,rho1tnew,fixed_lm=6)
!               WRITE(6,"(a,4f15.7)") "==GRID PAW ENERGIES (LM=6): ", ehart1(1), ehart1(2), ehart1t(1), ehart1t(2)
!               CALL coc_pwned (becstep, rho1new, rho1tnew,7)
!               CALL compute_onecenter_potentials(becstep,rho1new,rho1tnew,fixed_lm=7)
!               WRITE(6,"(a,4f15.7)") "==GRID PAW ENERGIES (LM=7): ", ehart1(1), ehart1(2), ehart1t(1), ehart1t(2)
!               CALL coc_pwned (becstep, rho1new, rho1tnew,8)
!               CALL compute_onecenter_potentials(becstep,rho1new,rho1tnew,fixed_lm=8)
!               WRITE(6,"(a,4f15.7)") "==GRID PAW ENERGIES (LM=8): ", ehart1(1), ehart1(2), ehart1t(1), ehart1t(2)
!               CALL coc_pwned (becstep, rho1new, rho1tnew,9)
!               CALL compute_onecenter_potentials(becstep,rho1new,rho1tnew,fixed_lm=9)
!               WRITE(6,"(a,4f15.7)") "==GRID PAW ENERGIES (LM=9): ", ehart1(1), ehart1(2), ehart1t(1), ehart1t(2)
#endif
              ! ---]] debug

              CALL compute_onecenter_charges (becstep, rho1new, rho1tnew)
              CALL compute_onecenter_potentials(becstep,rho1new,rho1tnew)
#ifdef DEBUG_PAW
                   WRITE(6,*) "==GRID PAW ENERGIES (HARTREE): "
                    WRITE(6,"(a,f15.10)") "==AE 1     :", ehart1(1)
                    WRITE(6,"(a,f15.10)") "==AE 2     :", ehart1(2)
                    WRITE(6,"(a,f15.10)") "==PS 1     :", ehart1t(1)
                    WRITE(6,"(a,f15.10)") "==PS 2     :", ehart1t(2)
                    WRITE(6,"(a,f15.10)") "==AE tot   :", SUM(ehart1(:))
                    WRITE(6,"(a,f15.10)") "==PS tot   :", SUM(ehart1t(:))
                    WRITE(6,"(a,f15.10)") "==AE-PS 1  :", ehart1(1)-ehart1t(1)
                    WRITE(6,"(a,f15.10)") "==AE-PS 2  :", ehart1(2)-ehart1t(2)
                    WRITE(6,"(a,f15.10)") "==AE-PS tot:", SUM(ehart1(:))-SUM(ehart1t(:))
                    WRITE(6,"(a,f15.10)") "================================================"
                    !
                    WRITE(6,"(a,f15.10)") "==GRID PAW ENERGIES (XC): "
                    DO i = 1,nat
                        WRITE(6,"(a,i2,a,f15.10)") "==AE",i,"     :", etxc1(i)
                        WRITE(6,"(a,i2,a,f15.10)") "==PS",i,"     :", etxc1t(i)
                        WRITE(6,"(a,i2,a,f15.10)") "==AE-PS",i,"  :", etxc1(i)-etxc1t(i)
                    ENDDO
                    WRITE(6,"(a,f15.10)") "==AE tot   :", SUM(etxc1(:))
                    WRITE(6,"(a,f15.10)") "==PS tot   :", SUM(etxc1t(:))
                    WRITE(6,"(a,f15.10)") "==AE-PS tot:", SUM(etxc1(:))-SUM(etxc1t(:))
#endif
              descf_1ae = delta_e_1scf(rho1, rho1new, vr1, descf_1ae_na)  ! AE
              descf_1ps = delta_e_1scf(rho1t,rho1tnew,vr1t,descf_1ps_na)  ! PS

              DEALLOCATE (rho1new, rho1tnew)
#ifdef DEBUG_PAW
              STOP
#endif
           END IF
           !!PAW]
           !
           ! ... estimate correction needed to have variational energy 
           !
           descf = delta_escf()
           !
           ! ... write the charge density to file
           !
           !TEMP
           CALL io_pot( 1, 'rho', rhonew, nspin )
           DEALLOCATE (rhonew )
           !TEMP
        ELSE
           !
           ! ... convergence reached: store V(out)-V(in) in vnew
           ! ... Used to correct the forces
           !
           CALL v_of_rho( rho, rho_core, nr1, nr2, nr3, nrx1, nrx2, nrx3,   &
                          nrxx, nl, ngm, gstart, nspin, g, gg, alat, omega, &
                          ehart, etxc, vtxc, etotefield, charge, vnew )
           !
           !!PAW[
            ! CHECKME: is it becsum or becstep??
           CALL compute_onecenter_potentials(becsum,rho1,rho1t)
           IF (okpaw) CALL infomsg ('electrons','PAW forces missing',-1)
           !!PAW]
           !
           vnew = vnew - vr
           !
           ! ... correction for variational energy no longer needed
           !
           descf = 0.D0
           !!PAW[
           IF (okpaw) then
              descf_1ae=0._DP
              descf_1ps=0._DP
              descf_1ae_na(:)=0.d0
              descf_1ps_na(:)=0.d0
           endif
           !!PAW]
           !
        END IF
#if defined (EXX)
        if (exxstart) then
           fock1 = exxenergy2()
           fock2 = fock0
        else
           fock0 = 0.d0
        end if
#endif
        !
        EXIT scf_step
        !
     END DO scf_step
     !
     ! ... define the total local potential (external + scf)
     !
     CALL set_vrs( vrs, vltot, vr, nrxx, nspin, doublegrid )
     !
     IF ( lda_plus_u ) THEN  
        !
        IF ( ionode ) THEN
           !
           CALL seqopn( iunocc, 'occup', 'FORMATTED', exst )
           !
           WRITE( iunocc, * ) ns
           !
           CLOSE( UNIT = iunocc, STATUS = 'KEEP' )
           !
        END IF
        !
     END IF
     !
     ! ... In the US case we need to recompute the self consistent term in
     ! ... the nonlocal potential.
     !
     !!PAW : newd contains PAW updates of NL coefficients
     CALL newd()
     !
     ! ... write the potential to file
     !
     CALL io_pot( 1, 'pot', vr, nspin )     
     !
     ! ... save converged wfc if they have not been written previously
     !     
     IF ( noncolin ) THEN
        !
        IF ( nks == 1 .AND. reduce_io ) &
           CALL davcio( evc_nc, nwordwfc, iunwfc, nks, 1 )
        !
     ELSE
        !
        IF ( nks == 1 .AND. reduce_io ) &
           CALL davcio( evc, nwordwfc, iunwfc, nks, 1 )
        !
     END IF
     IF(lelfield) CALL c_phase_field !in electric field case, calculate the polarization

     !
     ! ... write recover file
     !
     CALL save_in_electrons( iter, dr2 )
     !
     IF ( ( MOD(iter,report) == 0 ).OR. &
          ( report /= 0 .AND. conv_elec ) ) THEN
        !
        IF ( noncolin .and. domag ) CALL report_mag()
        !
     END IF
     !
     tcpu = get_clock( 'PWSCF' )
     WRITE( stdout, 9000 ) tcpu
     !
     IF ( conv_elec ) WRITE( stdout, 9101 )
     !
     CALL flush_unit( stdout )
     !
     IF ( ( conv_elec .OR. MOD( iter, iprint ) == 0 ) .AND. &
          ( .NOT. lmd ) ) THEN
        !
#if defined (__PARA)
        !
        ngkp(1:nks) = ngk(1:nks)
        !
        CALL ireduce( nks, ngkp )
        CALL ipoolrecover( ngkp, 1, nkstot, nks )
        CALL poolrecover( et, nbnd, nkstot, nks )
        !
#endif
        !
        DO ik = 1, nkstot
           !
           IF ( lsda ) THEN
              !
              IF ( ik == 1 ) WRITE( stdout, 9015)
              IF ( ik == ( 1 + nkstot / 2 ) ) WRITE( stdout, 9016)
              !
           END IF
           !
           IF ( conv_elec ) THEN
#if defined (__PARA)
              WRITE( stdout, 9021 ) ( xk(i,ik), i = 1, 3 ), ngkp(ik)
#else
              WRITE( stdout, 9021 ) ( xk(i,ik), i = 1, 3 ), ngk(ik)
#endif
           ELSE
              WRITE( stdout, 9020 ) ( xk(i,ik), i = 1, 3 )
           END IF
           !
           WRITE( stdout, 9030 ) ( et(ibnd,ik) * rytoev, ibnd = 1, nbnd )
           !
           IF( iverbosity > 0 ) THEN
               !
               ALLOCATE( wg_g( nbnd, nkstot ) )
               !
               wg_g = wg
               CALL poolrecover( wg_g, nbnd, nkstot, nks )
               !
               WRITE( stdout, 9032 )
               WRITE( stdout, 9030 ) ( wg_g(ibnd,ik), ibnd = 1, nbnd )
               !
               DEALLOCATE( wg_g )
               !
           END IF
           !
        END DO
        !
        IF ( lgauss .OR. ltetra ) then
           IF (two_fermi_energies) then
              WRITE( stdout, 9041 ) ef_up * rytoev, ef_dw * rytoev
           ELSE
              WRITE( stdout, 9040 ) ef * rytoev
           END IF
       ELSE
          !
          IF ( nspin == 1 ) THEN
             ibnd =  nint (nelec) / 2.d0
          ELSE
             ibnd =  nint (nelec)
          END IF
          !
          IF ( ionode .AND. nbnd > ibnd ) THEN
             !
             ehomo = MAXVAL ( et( ibnd  , 1:nkstot) )
             elumo = MINVAL ( et( ibnd+1, 1:nkstot) )
             !
             WRITE( stdout, 9042 ) ehomo * rytoev, elumo * rytoev
             !
          END IF
       END IF
        !
     END IF
     !
     IF ( ( ABS( charge - nelec ) / charge ) > 1.D-7 ) &
        WRITE( stdout, 9050 ) charge
     !
     etot = eband + ( etxc - etxcc ) + ewld + ehart + deband + demet + descf
     !!PAW[
     IF (okpaw) THEN
        !PRINT *, 'US energy before PAW additions', etot
        DO na = 1, nat
           IF (tpawp(ityp(na))) THEN
              !PRINT '(i3,8f9.3)', na,ehart1(na),ehart1t(na),             &
              !                    etxc1(na),etxc1t(na),                  &
              !                    deband_1ae_na(na), -deband_1ps_na(na), &
              !                    descf_1ae_na(na),-descf_1ps_na(na)
              correction1c = ehart1(na) -ehart1t(na) +etxc1(na) -etxc1t(na) + &
                             deband_1ae_na(na) - deband_1ps_na(na) +           &
                             descf_1ae_na(na) - descf_1ps_na(na)
              PRINT '(A,i3,f20.10)', 'atom # & correction:', na, correction1c
              IF (really_do_paw) etot = etot + correction1c
          END IF
        END DO
     END IF
     !!PAW]
#if defined (EXX)

     etot = etot - 0.5d0 * fock0

#endif
     !
#if defined (EXX)
     if (lexx .and. conv_elec ) then

        first = .not. exxstart

        CALL exxinit()

        if (first) then
           fock0 = exxenergy2()
           CALL v_of_rho( rho, rho_core, nr1, nr2, nr3, nrx1, nrx2, nrx3, &
                     nrxx, nl, ngm, gstart, nspin, g, gg, alat, omega, &
                     ehart, etxc, vtxc, etotefield, charge, vr )
           CALL set_vrs( vrs, vltot, vr, nrxx, nspin, doublegrid )
           write (*,*) " NOW GO BACK TO REFINE HF CALCULATION"
           write (*,*) fock0
           iter = 0
           go to 10
        end if
        fock2 = exxenergy2()
        !
        dexx = fock1 - 0.5d0 * ( fock0 + fock2 )

        etot = etot  - dexx

        write (*,*) fock0,fock1,fock2
        WRITE( stdout, 9066 ) dexx

        fock0 = fock2
        !
     end if
#endif
     !
     IF ( lda_plus_u ) etot = etot + eth
     IF ( tefield )    etot = etot + etotefield
     !
     IF ( ( conv_elec .OR. MOD( iter, iprint ) == 0 ) .AND. &
          ( .NOT. lmd ) ) THEN
        !  
        IF ( dr2 > eps8 ) THEN
           WRITE( stdout, 9081 ) etot, dr2
        ELSE
           WRITE( stdout, 9083 ) etot, dr2
        END IF
        !
        WRITE( stdout, 9060 ) &
            eband, ( eband + deband ), ehart, ( etxc - etxcc ), ewld
        !
#if defined (EXX)
        !
        WRITE( stdout, 9062 ) fock1
        WRITE( stdout, 9063 ) fock2
        WRITE( stdout, 9064 ) 0.5D0 * fock2
        !
#endif
        !
        IF ( tefield ) WRITE( stdout, 9061 ) etotefield
        IF ( lda_plus_u ) WRITE( stdout, 9065 ) eth
        IF ( degauss /= 0.0 ) WRITE( stdout, 9070 ) demet
        !
     ELSE IF ( conv_elec .AND. lmd ) THEN
        !
        IF ( dr2 > eps8 ) THEN
           WRITE( stdout, 9081 ) etot, dr2
        ELSE
           WRITE( stdout, 9083 ) etot, dr2
        END IF
        !
     ELSE
        !
        IF ( dr2 > eps8 ) THEN
           WRITE( stdout, 9080 ) etot, dr2
        ELSE
           WRITE( stdout, 9082 ) etot, dr2
        END IF
        !
     END IF
     !
     IF ( lsda ) WRITE( stdout, 9017 ) magtot, absmag
     !
     IF ( noncolin .AND. domag ) &
        WRITE( stdout, 9018 ) ( magtot_nc(i), i = 1, 3 ), absmag
     !
     IF ( i_cons == 3 .OR. i_cons == 4 )  &
        WRITE( stdout, 9071 ) bfield(1), bfield(2),bfield(3)
     IF ( i_cons == 5 ) &
        WRITE( stdout, 9072 ) bfield(3)
     IF ( i_cons /= 0 .AND. i_cons < 4 ) &
        WRITE( stdout, 9073 ) lambda
     !
     CALL flush_unit( stdout )
     !
     IF ( conv_elec ) THEN

#if defined (EXX)
        if (lexx .and. dexx > tr2 ) then
           write (*,*) " NOW GO BACK TO REFINE HF CALCULATION"
           iter = 0
           go to 10
        end if
#endif
        !
        WRITE( stdout, 9110 )
        !
        ! ... jump to the end
        !
        IF ( output_drho /= ' ' ) CALL remove_atomic_rho()
        !
        CALL stop_clock( 'electrons' )
        !TEMP
        DEALLOCATE (rhog)
        IF (okpaw) THEN
           DEALLOCATE (becstep)
           DEALLOCATE(deband_1ae_na, deband_1ps_na, descf_1ae_na, descf_1ps_na)
        END IF
        !TEMP
        !
        RETURN
        !
     END IF
     !
     ! ... uncomment the following line if you wish to monitor the evolution 
     ! ... of the force calculation during self-consistency
     !
     !CALL forces()
     !
  END DO
  !
  WRITE( stdout, 9101 )
  WRITE( stdout, 9120 )
  !
  CALL flush_unit( stdout )
  !
  IF ( output_drho /= ' ' ) CALL remove_atomic_rho()
  !
  CALL stop_clock( 'electrons' )
  !
  RETURN
  !
  ! ... formats
  !
9000 FORMAT(/'     total cpu time spent up to now is ',F9.2,' secs' )
9001 FORMAT(/'     Self-consistent Calculation' )
9010 FORMAT(/'     iteration #',I3,'     ecut=',F9.2,' ryd',5X,'beta=',F4.2 )
9015 FORMAT(/' ------ SPIN UP ------------'/ )
9016 FORMAT(/' ------ SPIN DOWN ----------'/ )
9017 FORMAT(/'     total magnetization       =', F9.2,' Bohr mag/cell', &
            /'     absolute magnetization    =', F9.2,' Bohr mag/cell' )
9018 FORMAT(/'     total magnetization       =',3f9.2,' Bohr mag/cell' &
       &   ,/'     absolute magnetization    =', f9.2,' Bohr mag/cell' )
9020 FORMAT(/'          k =',3F7.4,'     band energies (ev):'/ )
9021 FORMAT(/'          k =',3F7.4,' (',I6,' PWs)   bands (ev):'/ )
9030 FORMAT( '  ',8F9.4 )
9032 FORMAT(/'     occupation numbers ' )
9042 FORMAT(/'     highest occupied, lowest unoccupied level (ev): ',2F10.4 )
9041 FORMAT(/'     the spin up/dw Fermi energies are ',2F10.4,' ev' )
9040 FORMAT(/'     the Fermi energy is ',F10.4,' ev' )
9050 FORMAT(/'     integrated charge         =',F15.8 )
9060 FORMAT(/'     band energy sum           =',  F15.8,' ryd' &
            /'     one-electron contribution =',  F15.8,' ryd' &
            /'     hartree contribution      =',  F15.8,' ryd' &
            /'     xc contribution           =',  F15.8,' ryd' &
            /'     ewald contribution        =',  F15.8,' ryd' )
9061 FORMAT( '     electric field correction =',  F15.8,' ryd' )
9062 FORMAT( '     Fock energy 1             =',  F15.8,' ryd' )
9063 FORMAT( '     Fock energy 2             =',  F15.8,' ryd' )
9064 FORMAT( '     Half Fock energy 2        =',  F15.8,' ryd' )
9066 FORMAT( '     dexx                      =',  F15.8,' ryd' )
9065 FORMAT( '     Hubbard energy            =',F15.8,' ryd' )
9070 FORMAT( '     correction for metals     =',F15.8,' ryd' )
9071 FORMAT( '     Magnetic field            =',3F12.7,' ryd' )
9072 FORMAT( '     Magnetic field            =', F12.7,' ryd' )
9073 FORMAT( '     lambda                    =', F11.2,' ryd' )
9080 FORMAT(/'     total energy              =',0PF15.8,' ryd' &
            /'     estimated scf accuracy    <',0PF15.8,' ryd' )
9081 FORMAT(/'!    total energy              =',0PF15.8,' ryd' &
            /'     estimated scf accuracy    <',0PF15.8,' ryd' )
9082 FORMAT(/'     total energy              =',0PF15.8,' ryd' &
            /'     estimated scf accuracy    <',1PE15.1,' ryd' )
9083 FORMAT(/'!    total energy              =',0PF15.8,' ryd' &
            /'     estimated scf accuracy    <',1PE15.1,' ryd' )
9085 FORMAT(/'     total energy              =',0PF15.8,' ryd' &
            /'     potential mean squ. error =',1PE15.1,' ryd^2' )
9086 FORMAT(/'!    total energy              =',0PF15.8,' ryd' &
            /'     potential mean squ. error =',1PE15.1,' ryd^2' )
9101 FORMAT(/'     End of self-consistent calculation' )
9110 FORMAT(/'     convergence has been achieved' )
9120 FORMAT(/'     convergence NOT achieved, stopping' )
  !
  CONTAINS
     !
     !-----------------------------------------------------------------------
     SUBROUTINE non_scf()
       !-----------------------------------------------------------------------
       !
       !
       IMPLICIT NONE
       !
       REAL (DP), EXTERNAL :: efermit, efermig
       !
       !
       WRITE( stdout, 9002 )
       !
       CALL flush_unit( stdout )
       !
       iter = 1
       !
       ! ... diagonalization of the KS hamiltonian
       !
       if(lelfield) then
          do inberry=1,nberrycic
            ALLOCATE (psi(npwx,nbnd))
            do ik=1,nks
               call davcio(psi,nwordwfc,iunwfc,ik,-1)
               call davcio(psi,nwordwfc,iunefield,ik,1)
             enddo
             DEALLOCATE(psi)
            CALL c_bands( iter, ik_, dr2 )
          enddo
        else
          CALL c_bands( iter, ik_, dr2 )
        endif

       !
       conv_elec = .TRUE.
       !
       CALL poolrecover( et, nbnd, nkstot, nks )
       !
       tcpu = get_clock( 'PWSCF' )
       WRITE( stdout, 9000 ) tcpu
       !
       WRITE( stdout, 9102 )
       !
       ! ... write band eigenvalues
       !
       DO ik = 1, nkstot
          !
          IF ( lsda ) THEN
             !   
             IF ( ik == 1 ) WRITE( stdout, 9015 )
             IF ( ik == ( 1 + nkstot / 2 ) ) WRITE( stdout, 9016 )
             !
          END IF
          !
          WRITE( stdout, 9020 ) ( xk(i,ik), i = 1, 3 )
          WRITE( stdout, 9030 ) ( et(ibnd,ik) * rytoev, ibnd = 1, nbnd )
          !
       END DO
       !
       IF ( lgauss ) THEN
          !
          ef = efermig( et, nbnd, nks, nelec, wk, degauss, ngauss, 0, isk )
          !
          WRITE( stdout, 9040 ) ef * rytoev
          !
       ELSE IF ( ltetra ) THEN
          !
          ef = efermit( et, nbnd, nks, nelec, nspin, ntetra, tetra, 0, isk )
          !
          WRITE( stdout, 9040 ) ef * rytoev
          !
       ELSE
          !
          IF ( nspin == 1 ) THEN
             ibnd =  nint (nelec) / 2.d0
          ELSE
             ibnd =  nint (nelec)
          END IF
          !
          IF ( ionode .AND. nbnd > ibnd ) THEN
             !
             ehomo = MAXVAL ( et( ibnd  , 1:nkstot) )
             elumo = MINVAL ( et( ibnd+1, 1:nkstot) )
             !
             IF ( ehomo < elumo ) &
                  WRITE( stdout, 9042 ) ehomo * rytoev, elumo * rytoev
             !
          END IF
          !
       END IF
       !
       CALL flush_unit( stdout )
       !
       ! ... do a Berry phase polarization calculation if required
       !
       IF ( lberry ) CALL c_phase()
       !
       IF ( output_drho /= ' ' ) CALL remove_atomic_rho()
       !
       CALL stop_clock( 'electrons' )
       !
9000 FORMAT(/'     total cpu time spent up to now is ',F9.2,' secs' )
9002 FORMAT(/'     Band Structure Calculation' )
9015 FORMAT(/' ------ SPIN UP ------------'/ )
9016 FORMAT(/' ------ SPIN DOWN ----------'/ )
9020 FORMAT(/'          k =',3F7.4,'     band energies (ev):'/ )
9030 FORMAT( '  ',8F9.4 )
9040 FORMAT(/'     the Fermi energy is ',F10.4,' ev' )
9042 FORMAT(/'     Highest occupied, lowest unoccupied level (ev): ',2F10.4 )
9102 FORMAT(/'     End of band structure calculation' )
       !
     END SUBROUTINE non_scf
     !
     !-----------------------------------------------------------------------
     SUBROUTINE compute_magnetization()
       !-----------------------------------------------------------------------
       !
       IMPLICIT NONE
       !
       INTEGER :: ir
       !
       !
       IF ( lsda ) THEN
          !
          magtot = 0.D0
          absmag = 0.D0
          !
          DO ir = 1, nrxx
             !   
             mag = rho(ir,1) - rho(ir,2)
             !
             magtot = magtot + mag
             absmag = absmag + ABS( mag )
             !
          END DO
          !
          magtot = magtot * omega / ( nr1 * nr2 * nr3 )
          absmag = absmag * omega / ( nr1 * nr2 * nr3 )
          !
          CALL reduce( 1, magtot )
          CALL reduce( 1, absmag )
          !
       ELSE IF ( noncolin ) THEN
          !
          magtot_nc = 0.D0
          absmag    = 0.D0
          !
          DO ir = 1,nrxx
             !
             mag = SQRT( rho(ir,2)**2 + rho(ir,3)**2 + rho(ir,4)**2 )
             !
             DO i = 1, 3
                !
                magtot_nc(i) = magtot_nc(i) + rho(ir,i+1)
                !
             END DO
             !
             absmag = absmag + ABS( mag )
             !
          END DO
          !
          CALL reduce( 3, magtot_nc )
          CALL reduce( 1, absmag )
          !
          DO i = 1, 3
             !
             magtot_nc(i) = magtot_nc(i) * omega / ( nr1 * nr2 * nr3 )
             !
          END DO
          !
          absmag = absmag * omega / ( nr1 * nr2 * nr3 )
          !
       ENDIF
       !
       RETURN
       !
     END SUBROUTINE compute_magnetization
     !
     !-----------------------------------------------------------------------
     FUNCTION check_stop_now()
       !-----------------------------------------------------------------------
       !
       USE control_flags, ONLY : lpath
       USE check_stop,    ONLY : global_check_stop_now => check_stop_now
       !
       IMPLICIT NONE
       !
       LOGICAL :: check_stop_now
       INTEGER :: unit
       !
       !
       IF ( lpath ) THEN  
          !
          unit = iunpath
          !  
       ELSE
          !
          unit = stdout
          !   
       END IF
       !
       check_stop_now = global_check_stop_now( unit )
       !
       IF ( check_stop_now ) THEN
          !  
          conv_elec = .FALSE.
          !
          RETURN          
          !
       END IF              
       !
     END FUNCTION check_stop_now
     !
     !-----------------------------------------------------------------------
     FUNCTION delta_e ( )
       !-----------------------------------------------------------------------
       !
       ! ... delta_e = - \int rho(r) V_scf(r)
       !
       USE kinds
       !
       IMPLICIT NONE
       !   
       REAL (DP) :: delta_e
       !
       INTEGER :: ipol
       !
       !
       delta_e = 0.D0
       !
       DO ipol = 1, nspin
          !
          delta_e = delta_e - SUM( rho(:,ipol) * vr(:,ipol) )
          !
       END DO
       !
       delta_e = omega * delta_e / ( nr1 * nr2 * nr3 )
       !
       CALL reduce( 1, delta_e )
       !
       RETURN
       !
     END FUNCTION delta_e
     !
     !-----------------------------------------------------------------------
     FUNCTION delta_escf ( )
       !-----------------------------------------------------------------------
       !
       ! ... delta_escf = - \int \delta rho(r) V_scf(r)
       ! ... this is the correction needed to have variational energy
       !
       USE kinds
       !
       IMPLICIT NONE
       !   
       REAL(DP) :: delta_escf
       !
       INTEGER :: ipol
       !
       !
       delta_escf = 0.D0
       !
       DO ipol = 1, nspin
          !
          delta_escf = delta_escf - &
                       SUM( ( rhonew(:,ipol) - rho(:,ipol) ) * vr(:,ipol) )
          !
       END DO
       !
       delta_escf = omega * delta_escf / ( nr1 * nr2 * nr3 )
       !
       CALL reduce( 1, delta_escf )
       !
       RETURN
       !
     END FUNCTION delta_escf
     !
END SUBROUTINE electrons
