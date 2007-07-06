!
! Copyright (C) 2001-2003 PWSCF group
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!

#include "f_defs.h"
! FIXME: modularize code and remove the following includes
#include "../atomic/hartree.f90"
#include "../atomic/series.f90"
!
MODULE rad_paw_routines
  !
  IMPLICIT NONE
  PUBLIC
  SAVE
CONTAINS

!___   ___   ___   ___   ___   ___   ___   ___   ___   ___   ___   ___   ___
!!!!  !!!!  !!!!  !!!!  !!!!  !!!!  !!!!  !!!!  !!!!  !!!!  !!!!  !!!!  !!!!
!!! This function computes energy from potential and density on a radial grid
!!! if e_na is provided it's filled with per atom energies
!!
FUNCTION rad_energy(pot, rho, e_na, e_na_s_lm)
    USE kinds,                  ONLY : DP
    USE lsda_mod,               ONLY : nspin
    USE uspp_param,             ONLY : nhm, nh, lmaxq
    USE atom,                   ONLY : r, rab, mesh, msh
    USE parameters,             ONLY : ndmx
    USE ions_base,              ONLY : nat, ityp

    REAL(DP), INTENT(IN)             :: rho(ndmx,lmaxq**2,nspin,nat) ! input rho
    REAL(DP), INTENT(IN)             :: pot(ndmx,lmaxq**2,nspin,nat) ! input potential 
                                        ! (notice that it has only 4 dimensions)
    REAL(DP)                         :: rad_energy          ! output: total energy
    REAL(DP),OPTIONAL,INTENT(OUT)    :: e_na(nat)  ! optional output: energy per atom
    REAL(DP),OPTIONAL,INTENT(OUT)    :: e_na_s_lm(lmaxq**2,nspin,nat)
                                        ! optional output: energy per atom

    REAL(DP)                :: aux(ndmx)   ! workspace
    REAL(DP)                :: par_energy  ! workspace
    INTEGER                 :: na,ispin,lm !counters on atoms, spins, angular momentum
    CALL start_clock ('rad_energy')

    rad_energy = 0._dp
    IF (present(e_na)) e_na(:) = 0._dp
    IF (present(e_na_s_lm)) e_na_s_lm(:,:,:) = 0._dp

    atoms: DO na = 1, nat
    spins: DO ispin = 1,nspin
        DO lm = 1,lmaxq**2
            aux(:) = rho(:,lm,ispin,na) * pot(:,lm,ispin,na)
            ! V*rho is integrated using simpson algorithm
            CALL simpson (msh(ityp(na)),aux,rab(1,ityp(na)),par_energy)
            rad_energy = rad_energy + par_energy
            IF (present(e_na)) e_na(na) = e_na(na) +par_energy
            IF (present(e_na_s_lm)) e_na_s_lm(lm,ispin,na) = par_energy
        ENDDO
    ENDDO spins
    ENDDO atoms

    CALL stop_clock ('rad_energy')

END FUNCTION rad_energy

!___   ___   ___   ___   ___   ___   ___   ___   ___   ___   ___   ___   ___   ___   ___   ___
!!!!  !!!!  !!!!  !!!!  !!!!  !!!!  !!!!  !!!!  !!!!  !!!!  !!!!  !!!!  !!!!  !!!!  !!!!  !!!! 
!!! use the density produced by sum_rad_rho to compute potential (only hartree, at this moment)
!!
SUBROUTINE rad_potential(rho1rad, rho1trad, pot)
    USE kinds,                  ONLY : DP
    USE constants,              ONLY : fpi, eps8
    USE parameters,             ONLY : ndmx, npsx
    USE lsda_mod,               ONLY : nspin
    USE uspp_param,             ONLY : nhm, nh, lmaxq
    USE uspp,                   ONLY : ap
    USE ions_base,              ONLY : nat, ityp, ntyp => nsp
    USE atom,                   ONLY : r, mesh, msh

    REAL(DP), TARGET, INTENT(IN) :: rho1rad(ndmx,lmaxq**2,nspin,nat) ! AE charge density on rad. grid
    REAL(DP), TARGET, INTENT(IN) :: rho1trad(ndmx,lmaxq**2,nspin,nat)! the same, but pseudo
    REAL(DP), POINTER            :: rho1rad_(:,:,:,:)                ! pointer to both
    REAL(DP), TARGET, INTENT(OUT):: pot(ndmx,lmaxq**2,nspin,nat,2)   ! AE charge density on rad. grid
    REAL(DP)                     :: auxrho(ndmx)    ! workspace

    REAL(DP)                     :: r2(ndmx,npsx)    ! r**2
    REAL(DP)                     :: rs(ndmx,npsx)    ! r**.5
    REAL(DP)                     :: dx(npsx)         ! integration step used in atomic code
    REAL(DP)                     :: bogus !DEBUG

    INTEGER, PARAMETER           :: AE = 1, PS = 2   ! All-Electron and Pseudo
    INTEGER                      :: i_what, &
                                    na,nt, &     ! counter on atoms and atom types
                                    ispin, &     ! counter on spins
                                    lm,l,&       ! counter on composite angmom lm = l**2 +m
                                    k !DEBUG

    REAL(DP)                     :: e(nat,2) !DEBUG
    REAL(DP)                     :: ecomps(lmaxq**2,nspin,nat,2) !DEBUG
    CALL start_clock ('rad_pot')

    WRITE(6,*) "Compunting radial potentials..."
    
    ! prepare r**2 and r**.5 arrays                     !FIXME: move to init
    r2(:,:) = r(:,:)**2
    rs(:,:) = sqrt(r(:,:))

    !  I have to initialize the integration step dx:    !FIXME: move to init
    dx(:) = 0._dp
    DO nt = 1,ntyp
        IF (r(1,nt) > 0.0_dp) THEN
        ! r(i+1) = exp(xmin)/zmesh * exp(i*dx)
        dx(nt)=log(r(2,nt)/r(1,nt))
        ELSE
        ! r(i+1) = exp(xmin)/zmesh * ( exp(i*dx) - 1 )
        dx(nt)=log( (r(3,nt)-r(2,nt)) / r(2,nt) )
        ENDIF
    ENDDO


    ! this loop computes the hartree potential using the following formula:
    !               l is the first argument in hartree subroutine
    !               r1 = min(r,r'); r2 = MAX(r,r')
    ! V_h(r) = \sum{lm} Y_{lm}(\hat{r})/(2L+1) \int dr' 4\pi r'^2 \rho^{lm}(r') (r1^l/r2^{l+1})
    !     done here --> ^^^^^^^^^^^^^^^^^^^^^           ^^^^^^^^^^^^^^^^^^^^^^ <-- input to the hartree subroutine
    !                 output from the h.s. --> ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    whattodo: DO i_what = AE, PS
    NULLIFY(rho1rad_)
    IF (i_what == AE) THEN
        rho1rad_ => rho1rad
    ELSE IF (i_what == PS) THEN
        rho1rad_ => rho1trad
    ENDIF
        pot(:,:,:,:,:) = 0._dp
        atoms: DO na = 1, nat
        nt = ityp(na)
        spins: DO ispin = 1,nspin
            DO lm = 1, lmaxq**2
                l = INT(sqrt(DBLE(lm-1)))     ! l has to start from *zero*
                    auxrho(:) = fpi*rho1rad_(:,lm,ispin,na)/(2*l+1)
                    CALL hartree(l, 2*l+2, mesh(nt), r(:,nt),r2(:,nt),rs(:,nt),&
                                 dx(nt),auxrho(:), pot(:,lm,ispin,na,i_what))
                pot(:,lm,ispin,na,i_what)=pot(:,lm,ispin,na,i_what)
            ENDDO ! lm
!             DO lm = 1, lmaxq**2
!                 DO k = 1, mesh(nt)
!                     WRITE(10000*i_what+100*na+lm,"(2f15.8)") r(k,nt), pot(k,lm,ispin,na,i_what)
!                     WRITE(10000*(i_what+2)+100*na+lm,"(2f15.8)") r(k,nt), rho1rad_(k,lm,ispin,na)
!                     WRITE(10000*(i_what+4)+100*na+lm,"(2f15.8)") r(k,nt), rho1rad_(k,lm,ispin,na)*pot(k,lm,ispin,na,i_what)
!                 ENDDO
!                 WRITE(10000*i_what+100*na+lm,"()")
!                 WRITE(10000*(i_what+2)+100*na+lm,"()")
!                 WRITE(10000*(i_what+4)+100*na+lm,"()")
!             ENDDO
        ENDDO spins
        ENDDO atoms
        ![[-- debug
        DO na = 1,nat
             bogus = rad_energy(pot(:,:,:,:,i_what), rho1rad_,e(:,i_what),ecomps(:,:,:,i_what))
        ENDDO
        !debug --]]
    ENDDO whattodo

    WRITE(6,*) "==PAW RADIAL ENERGIES: "
    WRITE(6,*) "==AE 1     :", e(1,1)
    WRITE(6,*) "==AE 2     :", e(2,1)
!    WRITE(6,*) "AE 3     :", e(1,3)
    WRITE(6,*) "==PS 1     :", e(1,2)
    WRITE(6,*) "==PS 2     :", e(2,2)
!    WRITE(6,*) "PS 3     :", e(2,3)
    WRITE(6,*) "==AE tot   :", SUM(e(:,1))
    WRITE(6,*) "==PS tot   :", SUM(e(:,2))
    WRITE(6,*) "==AE-PS 1  :", e(1,1)-e(1,2)
    WRITE(6,*) "==AE-PS 2  :", e(2,1)-e(2,2)
!    WRITE(6,*) "AE-PS 3  :", e(1,3)-e(2,3)
    WRITE(6,"(a,2f15.7)") "==AE-PS tot:", SUM(e(:,1))-SUM(e(:,2))
    WRITE(6,"(a,2f15.7)") "== LM=1:",ecomps(1,1,1,1),ecomps(1,1,1,2)
    WRITE(6,"(a,2f15.7)") "== LM=2:",ecomps(2,1,1,1),ecomps(2,1,1,2)
    WRITE(6,"(a,2f15.7)") "== LM=3:",ecomps(3,1,1,1),ecomps(3,1,1,2)
    WRITE(6,"(a,2f15.7)") "== LM=4:",ecomps(4,1,1,1),ecomps(4,1,1,2)
    WRITE(6,"(a,2f15.7)") "== LM=5:",ecomps(5,1,1,1),ecomps(5,1,1,2)
    WRITE(6,"(a,2f15.7)") "== LM=6:",ecomps(6,1,1,1),ecomps(6,1,1,2)
    WRITE(6,"(a,2f15.7)") "== LM=7:",ecomps(7,1,1,1),ecomps(7,1,1,2)
    WRITE(6,"(a,2f15.7)") "== LM=8:",ecomps(8,1,1,1),ecomps(8,1,1,2)
    WRITE(6,"(a,2f15.7)") "== LM=9:",ecomps(9,1,1,1),ecomps(9,1,1,2)
    WRITE(6,"(a,2f15.7)") "=============================================="

    CALL stop_clock ('rad_pot')

END SUBROUTINE rad_potential

!___   ___   ___   ___   ___   ___   ___   ___   ___   ___   ___   ___   ___   ___   ___
!!!!  !!!!  !!!!  !!!!  !!!!  !!!!  !!!!  !!!!  !!!!  !!!!  !!!!  !!!!  !!!!  !!!!  !!!!
!!! sum up pfuncs x occupation in order to build radial density's angular momentum components
!!
SUBROUTINE sum_rad_rho(bec, rho1rad, rho1trad)
    USE kinds,                  ONLY : DP
    USE constants,              ONLY : eps8
    USE atom,                   ONLY : r, rab, mesh, msh
    USE ions_base,              ONLY : nat, ityp, ntyp => nsp
    USE lsda_mod,               ONLY : nspin
    USE uspp_param,             ONLY : nhm, nh, lmaxq, augfun
    USE uspp,                   ONLY : indv, ap, nhtolm,lpl,lpx
    USE parameters,             ONLY : ndmx
    USE grid_paw_variables,     ONLY : okpaw, tpawp, pfunc, ptfunc


    INTEGER, PARAMETER           :: AE = 1, PS = 2   ! All-Electron and Pseudo

    REAL(DP), INTENT(IN)         :: bec(nhm*(nhm+1)/2,nat,nspin)     ! cross band occupation
    REAL(DP), TARGET, INTENT(OUT):: rho1rad(ndmx,lmaxq**2,nspin,nat) ! AE charge density on rad. grid
    REAL(DP), TARGET, INTENT(OUT):: rho1trad(ndmx,lmaxq**2,nspin,nat)! the same, but pseudo
    REAL(DP), POINTER            :: rho1rad_(:,:,:,:)                ! pointer to rho1rad & rho1trad
    REAL(DP), POINTER            :: pfunc_(:,:,:,:)                  ! pointer to pfunc and ptfunc
    REAL(DP)                     :: pref                             ! workspace

    INTEGER                 :: i_what, &    ! counter on AE/pseudo
                               nb,mb, &     ! counters for pfunc nb,mb = 1, nh
                               nmb, &       ! composite "triangular" index for pfunc nmb = 1,  nh*(nh+1)/2
                               lm,lp,l,m, &    ! counters for angular momentum lm = l**2+m
                               nt,na, &     ! counters for pseudo type and atom nt = indv(na)
                               ispin,&        ! counter for spin (FIXME: may be unnecessary)
                               k !DEBUG

    ! This functions computes the various angular momentum components of rho
    ! using the following formula:
    !   rho(\vec{r}) = \sum_{LM} Y_{LM} \sum_{i,j} (\hat{r}) a_{LM}^{(lm)_i(lm)_j} becsum_ij pfunc_ij(r)
    !
    ! actually different angular momentum components are stored separately:
    !   rho^{LM}(\vec{r}) = \sum_{i,j} (\hat{r}) a_{LM}^{(lm)_i(lm)_j} becsum_ij pfunc_ij(r)
    !
    ! notice that pfunc's are already multiplied by r^2 and they are indexed on the atom
    ! (they only depends on l, not on m), the augmentation charge that has to be added for
    ! the pseudo part depend on both l and m

    CALL start_clock ('sum_rad_rho')
    WRITE(6,*) "RADIAL PAW ROUTINES: sum rad rho"

    whattodo: DO i_what = AE, PS
    NULLIFY(rho1rad_, pfunc_)
    IF (i_what == AE) THEN
        rho1rad_ => rho1rad
        pfunc_   => pfunc
    ELSE IF (i_what == PS) THEN
        rho1rad_ => rho1trad
        pfunc_   => ptfunc
    ENDIF
        rho1rad_(:,:,:,:)  = 0._dp
        !
        atoms: DO na = 1, nat
        nt = ityp(na) ! "nt" is the pseudopot (the type) of atom "na"
        ifpaw: IF (tpawp(nt)) THEN
            spins: DO ispin = 1, nspin
            nmb = 0
                ! loop on all pfunc for this kind of pseudo
                DO nb = 1, nh(nt)
                DO mb = nb, nh(nt)
                    nmb = nmb+1 ! nmb = 1, nh*(nh+1)/2
!                   DO lm = 1, lmaxq**2  ! loop on all lm has been replaced by lpl+lpx trick
                    DO lp = 1, lpx (nhtolm(mb,nt), nhtolm(nb,nt)) !lmaxq**2
                       lm = lpl (nhtolm(mb,nt), nhtolm(nb,nt), lp)
!                        check no more necessary as the lp --> lm trick works the same
!                        IF ( ABS(ap(lm, nhtolm(mb,nt), nhtolm(nb,nt))) > eps8 ) THEN
                            ! becsum already contains a factor 2 for off-diagonal pfuncs
                        pref = bec(nmb,na,ispin) * ap(lm, nhtolm(nb,nt), nhtolm(mb,nt))
                        !
                        rho1rad_(1:msh(nt),lm,ispin,na) = rho1rad_(1:msh(nt),lm,ispin,na) +&
                                        pref * pfunc_(1:msh(nt), indv(nb,nt), indv(mb,nt), nt)
                        IF (i_what == PS) THEN
                            ! if I'm doing the pseudo part I have to add the augmentation charge
                            l = INT(sqrt(DBLE(lm-1))) ! l has to start from zero
                            rho1rad_(1:msh(nt),lm,ispin,na) = rho1rad_(1:msh(nt),lm,ispin,na) +&
                                        pref * augfun(1:msh(na), indv(nb,nt), indv(mb,nt), l, nt)
                        ENDIF ! i_what == PS
!                        ENDIF ! |ap| > 1.0e-8
                    ENDDO ! lm
!                     DO k = 1, msh(nt)
!                         WRITE(90000+1000*i_what+100*na+10*nb+mb,"(2f15.8)")&
!                                r(k,nt), pfunc_(k,indv(nb,nt),indv(mb,nt),nt)
!                     ENDDO
                ENDDO !mb
                ENDDO !nb
            ENDDO spins
        ENDIF ifpaw
        ENDDO atoms
    ENDDO whattodo

    CALL stop_clock ('sum_rad_rho')

END SUBROUTINE sum_rad_rho




SUBROUTINE integrate_pfunc
    !
    USE kinds,      ONLY : DP
    USE parameters, ONLY : lmaxx, nbrx, lqmax, ndmx
    USE constants,  ONLY : fpi, eps8, eps4
    USE atom,       ONLY : r, rab, mesh, msh
    USE ions_base,  ONLY : ntyp => nsp
    USE cell_base,  ONLY : omega, tpiba
    USE gvect,      ONLY : g, gg
    USE lsda_mod,   ONLY : nspin
    USE us,         ONLY : nqxq, dq, nqx, tab, qrad
    USE uspp 
    USE uspp_param 
    USE spin_orb,   ONLY : lspinorb, rot_ylm, fcoef
    !
    USE grid_paw_variables, ONLY: tpawp, pfunc, ptfunc, pp, ppt, prad, ptrad, okpaw
    ! for FFt method
    USE gvect,         ONLY : gg, gi =>gstart, ngm
    USE grid_paw_routines, ONLY: pvan2
    !
    IMPLICIT NONE
    !, int_pfunc_(:,:,:)
    REAL(DP), POINTER :: pfunc_(:,:,:,:), prad_(:,:,:,:), pp_(:,:,:), int_pfunc_(:,:,:,:,:)
    REAL(DP),TARGET   :: int_pfunc(nbrx,nbrx,nbrx,nbrx,ntyp),&
                         int_ptfunc(nbrx,nbrx,nbrx,nbrx,ntyp)
    REAL(DP)          :: integral, ap2
    !
    INTEGER :: i_what, terms
    REAL(DP) :: aux2(ndmx)
    !
    ! here a few local variables
    !
    INTEGER :: nt, ih, jh, nb, mb, nc, mc, nmb, l, m, lm, ir, iq, is, ndm ! various counters
    REAL(DP), ALLOCATABLE :: aux (:), aux1 (:)
    ! various work space
    INTEGER :: n1, m0, m1, n, li, mi, vi, vj, ijs, is1, is2, &
              lk, mk, vk, kh, lh, sph_ind, nnbrx, ll,j
    COMPLEX(DP) :: coeff, qgm(1)
    REAL(DP) :: ap_tot
    REAL(DP) :: spinor, ji, jk

    ! for FFT method
    REAL(DP), ALLOCATABLE :: qmod (:),  & ! the modulus of G
                             ylmk0 (:,:)  ! the spherical harmonics
    COMPLEX(DP), ALLOCATABLE  :: pft(:,:,:)  ! the AE/PS wfc products
    COMPLEX(DP), TARGET  :: int_pfunc_fft(nbrx,nbrx,nbrx,nbrx, ntyp),&  ! the AE/PS wfc products
                            int_ptfunc_fft(nbrx,nbrx,nbrx,nbrx, ntyp)
    COMPLEX(DP), POINTER :: int_pfunc_fft_(:,:,:,:,:)
    INTEGER :: terms_counter(9,9,9,9,2,1)

WRITE(6,*) "RADIAL PAW ROUTINES: integrate_pfunc (start)"

RETURN
    !
    ! part1: compute P_ij * P_ab on radial, real space, grid
    !--------------------------------------------------------------------------------

whattodo: DO i_what=1, 2
       ! associate a pointer to the AE or PS part
       NULLIFY(pfunc_,int_pfunc_)
       IF (i_what==1) THEN
          pfunc_=> pfunc
          int_pfunc_ => int_pfunc
       ELSE IF (i_what==2) THEN
          pfunc_=> ptfunc
          int_pfunc_ => int_ptfunc
       END IF
       ! Compute the integrals of pfunc
       DO nt = 1, ntyp ! ntype is the # of atomic species (PP's) is .le. than the # of atoms
          IF (tpawp(nt)) THEN
            ! I have to cicle on pfunc TWICE, and each pfunc has 2 indexes => 4 indexes
            ih = 0
            DO nc = 1, nh(nt)
            DO mc = 1, nh(nt)
                DO nb = 1, nh(nt)
                DO mb = 1, nh(nt)
!                    WRITE(6,*) MAXVAL(pfunc_(1:msh(nt), nb, mb, nt))
                    ih = ih+1
                    int_pfunc_(nc,mc,nb,mb,nt) = 0._DP
                    terms = 0
                    DO lm = 1, lmaxq**2 ! FIXME: is this the right upper bound??
                        ap2 = ap(lm,nhtolm(nc,nt),nhtolm(mc,nt))*ap(lm,nhtolm(nb,nt),nhtolm(mb,nt))
                        IF ( ABS(ap2) > eps8 ) THEN
                            terms = terms +1
                            ! if I don't have the augfun the integral have to be computed only once
                            IF ((i_what == 1) .and. (terms == 1)) THEN
                                aux2(1:msh(nt)) = (pfunc_(1:msh(nt), indv(nb,nt), indv(mb,nt), nt)/r(1:msh(nt),nt))*&
                                                  (pfunc_(1:msh(nt), indv(nc,nt), indv(mc,nt), nt)/r(1:msh(nt),nt))
                                CALL simpson (msh(nt),aux2,rab(1,nt),integral)
                            ENDIF
                            ! with the augfun than I have to compute the integral for each value of lm
                            IF ((i_what == 2)) THEN
                                l = INT(sqrt(DBLE(lm-1))) ! the "+1" is not required, as augfun are labelled 0..l
                                aux2(1:msh(nt)) = (pfunc_(1:msh(nt), indv(nb,nt), indv(mb,nt), nt)&
                                                    +augfun(1:msh(nt), indv(nb,nt), indv(mb,nt), l, nt))/r(1:msh(nt),nt)*&
                                                  (pfunc_(1:msh(nt), indv(nc,nt), indv(mc,nt), nt)&
                                                    +augfun(1:msh(nt), indv(nc,nt), indv(mc,nt), l, nt))/r(1:msh(nt),nt)
                                ! the following line is duplicated (better than using two IF..THEN)
                                CALL simpson (msh(nt),aux2,rab(1,nt),integral)
                            ENDIF
                            ! anyway I have to sum
                            int_pfunc_(nc,mc,nb,mb,nt) = int_pfunc_(nc,mc,nb,mb,nt) + integral*ap2
                        ENDIF
                    ENDDO ! l = 1, lmaxq
                    IF (terms > 0.and. i_what==2)&
                       WRITE(1001,"(i4,2i4,3i2,f14.8,i3,2f8.4)"), ih,i_what,nc,mc,nb,mb,  int_pfunc_(nc,mc,nb,mb,nt),&
                                   terms,integral, ap2
                    terms_counter(nc,mc,nb,mb,i_what,nt) = terms
                END DO !mb
                END DO !nb 
            END DO !mc
            END DO !nc 
            !
          END IF ! tpawp
       END DO ! nt
    END DO whattodo

    !
    ! part2: the same in FFT
    !--------------------------------------------------------------------------------
    WRITE(6,*) "done: radial"
    ALLOCATE (qmod(ngm), pft(ngm,nbrx,nbrx), ylmk0(ngm,lmaxq*lmaxq))
    !
    CALL ylmr2 (lmaxq * lmaxq, ngm, g, gg, ylmk0)
    qmod(:) = SQRT(gg(:))
    !
    whattodo2: DO i_what=1, 2
        !
        NULLIFY(prad_,int_pfunc_fft_)
        IF (i_what==1) THEN
            prad_ => prad
            int_pfunc_fft_ => int_pfunc_fft
        ELSE IF (i_what==2) THEN
            ! ***NOTE: ptrad already has the augmentation charge***
            prad_ => ptrad
            int_pfunc_fft_ => int_ptfunc_fft
        END IF
         pft(:,:,:) = 0._DP !probably unnecessary
        !
        int_pfunc_fft_ (:,:,:,:,:)  = (0.d0, 0.d0)
        !
        DO nt = 1, ntyp
            ih = 0
            pft (:,:,:) = (0.d0, 0.d0)
            IF (tpawp(nt)) THEN
                DO nc = 1, nh (nt)
                DO mc = 1, nh (nt)
                    CALL pvan2 (ngm, mc, nc, nt, qmod, pft(1,nc,mc), ylmk0, prad_, &
                        SIZE(prad_,1),SIZE(prad_,2),SIZE(prad_,3),SIZE(prad_,4))
                ENDDO ! jh
                ENDDO ! ih

                DO nc = 1, nh(nt)
                DO mc = 1, nh(nt)
                    DO nb = 1, nh(nt)
                    DO mb = 1, nh(nt)
                    ih = ih+1
                    int_pfunc_fft_ (mb,nb,mc,nc, nt) = OMEGA *& 
                    SUM( DBLE( CONJG(pft(:,mc,nc))*pft(:,mb,nb) ))
                    !
                    !int_pfunc_fft_ (ijh2, ijh, nt) = CONJG( int_pfunc_fft_ (ijh, ijh2, nt) )
                 !
                    IF (ABS(int_pfunc_fft_(nc,mc,nb,mb,nt))>eps8 .and. i_what==2) &
                        WRITE(1002,"(i4,2i4,3i2,2f14.8)"), ih,i_what,nc,mc,nb,mb,  int_pfunc_fft_(nc,mc,nb,mb,nt)
                    ENDDO ! mb
                    ENDDO ! nb
                ENDDO ! mc
                ENDDO ! nc
            ENDIF ! tpawp
        ENDDO ! nt
     !
    ENDDO whattodo2
    !
    DEALLOCATE (qmod, pft, ylmk0) 
    WRITE(6,*) "done: FFT"

    lm = 1
    whattodo3: DO i_what=1, 2
        !
        NULLIFY(prad_,int_pfunc_fft_,int_pfunc_)
        IF (i_what==1) THEN
            int_pfunc_ => int_pfunc
            int_pfunc_fft_ => int_pfunc_fft
        ELSE IF (i_what==2) THEN
            int_pfunc_ => int_ptfunc
            int_pfunc_fft_ => int_ptfunc_fft
        END IF
        DO nt = 1, ntyp
            ih = 0
            IF (tpawp(nt)) THEN
                DO nc = 1, nh(nt)
                DO mc = 1, nh(nt)
                    DO nb = 1, nh(nt)
                    DO mb = 1, nh(nt)
!                 DO nc = 1, nh(nt)
!                 DO mc = nc, nh(nt)
!                     DO nb = mc, nh(nt)
!                     DO mb = nb, nh(nt)
                        ih = ih+1
                        IF( ABS(int_pfunc_(nc,mc,nb,mb,nt) - int_pfunc_fft_(nc,mc,nb,mb,nt)) > eps4) THEN
                            WRITE(1003,"(3i4,3i2,f14.8,f16.8,f14.8,i3,4i2,a)"), ih,i_what,nc,mc,nb,mb, &
                             int_pfunc_(nc,mc,nb,mb,nt), int_pfunc_fft_(nc,mc,nb,mb,nt),terms_counter(nc,mc,nb,mb,i_what,nt),&
                             nhtolm(nc,nt),nhtolm(mc,nt),nhtolm(nb,nt),nhtolm(mb,nt),"yadda"
                        ELSE IF ( ABS(int_pfunc_(nc,mc,nb,mb,nt)) > eps8 ) THEN
                            WRITE(1004,"(3i4,3i2,f14.8,f16.8,f14.8,i3,4i2,a)"),ih,i_what,nc,mc,nb,mb, &
                             int_pfunc_(nc,mc,nb,mb,nt), int_pfunc_fft_(nc,mc,nb,mb,nt), terms_counter(nc,mc,nb,mb,i_what,nt),&
                             nhtolm(nc,nt),nhtolm(mc,nt),nhtolm(nb,nt),nhtolm(mb,nt),"blah"
                        ENDIF
                    ENDDO ! mb
                    ENDDO ! nb
                ENDDO ! mc
                ENDDO ! nc
            ENDIF ! tpawp
        ENDDO ! nt
    ENDDO whattodo3
WRITE(6,*) "RADIAL PAW ROUTINES: integrate_pfunc (end)"

STOP

END SUBROUTINE integrate_pfunc


! analogous to compute_onecenter_charges
!
  SUBROUTINE coc_pwned(becnew, rho1new, rho1tnew,lm)
    !
    USE kinds,                ONLY : DP
    USE constants,            ONLY : eps8
    USE ions_base,            ONLY : nat, ntyp => nsp, ityp, tau, atm
    USE gvect,                ONLY : nr1, nr2, nr3, nrx1, nrx2, nrx3, nrxx, &
                                     ngm, nl, nlm, gg, g
    USE lsda_mod,             ONLY : nspin
    USE uspp_param,           ONLY : lmaxq, tvanp, nh, nhm
    USE wvfct,                ONLY : gamma_only
    USE wavefunctions_module, ONLY : psic
    !
    USE grid_paw_variables, ONLY: prad, ptrad, pp, tpawp, okpaw
    USE grid_paw_routines
    USE us,                 ONLY: qrad
    USE uspp,                   ONLY : indv, ap, nhtolm
    !
    IMPLICIT NONE
    !
    !first input-output variables
    ! 
    REAL(DP), INTENT(IN) :: becnew (nhm*(nhm+1)/2,nat,nspin)
    REAL(DP), TARGET, INTENT(OUT) :: &
         rho1new(nrxx, nspin, nat), rho1tnew(nrxx,nspin,nat)
    !
    INTEGER :: ig, na, nt, ih, jh, ijh, is ! counters
    INTEGER,INTENT(IN) :: lm!DEBUG
    !
    REAL(DP), ALLOCATABLE :: qmod (:), & ! the modulus of G
                             ylmk0 (:,:) ! the spherical harmonics
    COMPLEX(DP), ALLOCATABLE :: aux (:,:,:), & ! work space for rho(G,nspin)
                                qgm(:)         ! Fourier transform of q

    REAL(DP), POINTER :: rho1_(:,:,:), prad_(:,:,:,:)
    INTEGER :: i_what

    IF (.NOT.okpaw) RETURN
    call start_clock ('one-charge')

    ALLOCATE (aux(ngm,nspin,nat), qmod(ngm), qgm(ngm), ylmk0(ngm,lmaxq*lmaxq))    
    !  
    CALL ylmr2 (lmaxq * lmaxq, ngm, g, gg, ylmk0)
    qmod(:) = SQRT(gg(:))

    WRITE(20,*) "becsum used in GRID:"
    DO i_what =1,2
        atoms: DO na = 1, nat
        nt = ityp(na)
            spins: DO is = 1, nspin
            ijh = 0
                ! loop on all pfunc for this kind of pseudo
                DO ih = 1, nh(nt)
                DO jh = ih, nh(nt)
                    ijh = ijh+1
                    WRITE(20,"(a,i3,a,4i3,f12.6)") "-->",ijh,":",ih,jh,na,is,becnew(ijh,na,is)
                ENDDO
                ENDDO
            ENDDO spins
        ENDDO atoms
    ENDDO

    whattodo: DO i_what=1, 2
       NULLIFY(prad_,rho1_)
       IF (i_what==1) THEN
          prad_ => prad
          rho1_ => rho1new
       ELSE IF (i_what==2) THEN
          prad_ => ptrad
          rho1_ => rho1tnew
       END IF
       aux (:,:,:) = (0.d0, 0.d0)

       DO nt = 1, ntyp
          IF (tpawp (nt) ) THEN
             ijh = 0
             DO ih = 1, nh (nt)
                DO jh = ih, nh (nt)
                   !
                   ijh = ijh + 1
                   CALL pvan2_pwned (ngm, ih, jh, nt, qmod, qgm, ylmk0, prad_, &
                        SIZE(prad_,1),SIZE(prad_,2),SIZE(prad_,3),SIZE(prad_,4),lm)
                   DO na = 1, nat
                      !
                      IF (ityp(na).NE.nt) CYCLE
                      DO is = 1, nspin
!________________________________________________________________________
!                        lm: DO lm = 1, lmaxq**2
!                        ap__: IF ( ABS(ap(lm, nhtolm(ih,nt), nhtolm(jh,nt))) > eps8 ) THEN
!________________________________________________________________________

                         DO ig = 1, ngm
                            aux(ig,is,na) = aux(ig,is,na) +         &
                                            !ap(lm, nhtolm(ih,ityp(na)), nhtolm(jh,ityp(na)))*&
                                            qgm(ig)*becnew(ijh,na,is)
                         ENDDO
!________________________________________________________________________
!                      ENDIF ap__
!                      ENDDO lm
!________________________________________________________________________
                      ENDDO
                      !
                   ENDDO
                   !
                ENDDO
             ENDDO
          ENDIF
       ENDDO
       !
       !     convert aux to real space
       !
       DO na = 1, nat
          IF (tpawp(ityp(na))) THEN
             DO is = 1, nspin
                psic(:) = (0.d0, 0.d0)
                psic( nl(:) ) = aux(:,is,na)
                IF (gamma_only) psic( nlm(:) ) = CONJG(aux(:,is,na))
                CALL cft3 (psic, nr1, nr2, nr3, nrx1, nrx2, nrx3, 1)
                rho1_ (:, is, na) = DBLE (psic (:) )
             ENDDO
          END IF
       END DO
       !
    END DO whattodo
    !
    DEALLOCATE (ylmk0, qgm, qmod, aux)
    call stop_clock ('one-charge')

  END SUBROUTINE coc_pwned


  ! Analogous to PW/qvan2.f90
  SUBROUTINE pvan2_pwned (ngy, ih, jh, np, qmod, qg, ylmk0, prad_, s1, s2, s3, s4,lm)
    !
    !#include "f_defs.h"
    USE kinds, ONLY: DP
    USE us, ONLY: dq!, qrad
    USE uspp_param, ONLY: lmaxq, nbrx
    USE uspp, ONLY: nlx, lpl, lpx, ap, indv, nhtolm
    IMPLICIT NONE

    INTEGER, INTENT(IN) :: s1,s2,s3,s4
    REAL(DP), INTENT(IN) :: prad_(s1,s2,s3,s4)
    INTEGER,INTENT(IN) :: lm

    INTEGER :: ngy, & ! input: the number of G vectors to compute
               ih,  & ! input: the first index of Q
               jh,  & ! input: the second index of Q
               np     ! input: the number of the pseudopotential

    REAL(DP) :: ylmk0 (ngy, lmaxq * lmaxq), & ! the spherical harmonics
                qmod (ngy)         ! input:  moduli of the q+g vectors
    COMPLEX(DP) :: qg (ngy)        ! output: the fourier transform of interest
    !
    !     here the local variables
    !
    COMPLEX(DP) :: sig ! (-i)^L

    INTEGER :: nb,          & ! the atomic index corresponding to ih
               mb,          & ! the atomic index corresponding to jh
               nmb,         & ! combined index (nb,mb)
               ivl,         & ! the lm corresponding to ih
               jvl,         & ! the lm corresponding to jh
               ig,          & ! counter on g vectors
               lp,          & ! the actual LM
               l,           & ! the angular momentum L
!               lm,          & ! the possible LM's compatible with ih,j
               i0, i1, i2, i3 ! counters for interpolation table

    REAL(DP) :: sixth,                & ! 1 divided by six
                dqi,                  & ! 1 divided dq
                qm,                   & ! qmod/dq
                px,                   & ! measures for interpolation table
                ux, vx, wx, uvx, pwx, & ! auxiliary variables for intepolation
                work                    ! auxiliary variable
    !
    LOGICAL :: new_qmod
    !
    ! compute the indices which correspond to ih,jh
    !
    call start_clock ('pvan2')
    sixth = 1.d0 / 6.d0
    dqi = 1 / dq
    nb = indv (ih, np)
    mb = indv (jh, np)
    IF (nb.GE.mb) THEN
       nmb = nb * (nb - 1) / 2 + mb
    ELSE
       nmb = mb * (mb - 1) / 2 + nb
    ENDIF
    ivl = nhtolm(ih, np)
    jvl = nhtolm(jh, np)
    IF (nb.GT.nbrx) CALL errore (' pvan2 ', ' nb.gt.nbrx ', nb)
    IF (mb.GT.nbrx) CALL errore (' pvan2 ', ' mb.gt.nbrx ', mb)
    IF (ivl.GT.nlx) CALL errore (' pvan2 ', ' ivl.gt.nlx  ', ivl)
    IF (jvl.GT.nlx) CALL errore (' pvan2 ', ' jvl.gt.nlx  ', jvl)
    qg(:) = (0.d0, 0.d0)
    !
    !    and make the sum over the non zero LM
    !
    !DO lm = 1, lpx (ivl, jvl)
       !lp = lpl (ivl, jvl, lm)
        lp=lm
       !
       ! extraction of angular momentum l from lp:
       !
       if (lp<1)  CALL errore (' qvan ', ' lp < 1 ', lp)
       l = sqrt(DBLE(lp-1)) + 1
       if (lp>49) CALL errore (' qvan ', ' lp > 49 ', lp)
       !
       sig = (0.d0, -1.d0) ** (l - 1)
       sig = sig * ap (lp, ivl, jvl)
       !
       new_qmod = .true.
       DO ig = 1, ngy
          !
          ! calculate quantites depending on the module of G only when needed
          !
          IF ( ig > 1 ) new_qmod = ABS( qmod(ig) - qmod(ig-1) ) > 1.0D-6
          IF ( new_qmod ) THEN
             qm = qmod (ig) * dqi
             px = qm - INT (qm)
             ux = 1.d0 - px
             vx = 2.d0 - px
             wx = 3.d0 - px
             i0 = INT( qm ) + 1
             i1 = i0 + 1
             i2 = i0 + 2
             i3 = i0 + 3
             uvx = ux * vx * sixth
             pwx = px * wx * 0.5d0
             work = prad_ (i0, nmb, l, np) * uvx * wx + &
                    prad_ (i1, nmb, l, np) * pwx * vx - &
                    prad_ (i2, nmb, l, np) * pwx * ux + &
                    prad_ (i3, nmb, l, np) * px * uvx
          ENDIF
          qg (ig) = qg (ig) + sig * ylmk0 (ig, lp) * work
       ENDDO
    !ENDDO
    call stop_clock ('pvan2')

    RETURN
  END SUBROUTINE pvan2_pwned


END MODULE rad_paw_routines
