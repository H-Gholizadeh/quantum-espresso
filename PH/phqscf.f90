!
! Copyright (C) 2001-2008 Quantum_ESPRESSO group
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!
!
!-----------------------------------------------------------------------
SUBROUTINE phqscf
  !-----------------------------------------------------------------------
  !
  !     This subroutine is the main driver of the self consistent cycle
  !     which gives as output the change of the wavefunctions and the
  !     change of the self-consistent potential due to a phonon of
  !     a fixed q or to an electric field.
  !
  USE kinds, ONLY : DP
  USE ions_base, ONLY : nat
  USE gvect, ONLY : nrxx
  USE lsda_mod, ONLY : nspin
  USE io_global,  ONLY : stdout, ionode
  USE uspp,  ONLY: okvan
  USE efield_mod, ONLY : zstarue0, zstarue0_rec
  USE control_ph, ONLY : zue, convt, rec_code
  USE partial,    ONLY : done_irr, comp_irr
  USE modes,      ONLY : nirr, npert, npertx
  USE phus,       ONLY : int3, int3_nc, int3_paw
  USE uspp_param, ONLY : nhm
  USE paw_variables, ONLY : okpaw
  USE noncollin_module, ONLY : noncolin, nspin_mag
  USE recover_mod, ONLY : write_rec

  USE mp_global,  ONLY : inter_pool_comm, intra_pool_comm
  USE mp,         ONLY : mp_sum

  IMPLICIT NONE

  INTEGER :: irr, irr1, imode0
  ! counter on the representations
  ! counter on the representations
  ! counter on the modes

  REAL(DP) :: tcpu, get_clock
  ! timing variables

  LOGICAL :: exst
  ! used to test the recover file

  EXTERNAL get_clock
  ! the change of density due to perturbations

  COMPLEX(DP), ALLOCATABLE :: drhoscf (:,:,:)

  CALL start_clock ('phqscf')
  !
  !    For each irreducible representation we compute the change
  !    of the wavefunctions
  !
  ALLOCATE (drhoscf( nrxx , nspin_mag, npertx))    
  DO irr = 1, nirr
     IF ( (comp_irr (irr) == 1) .AND. (done_irr (irr) == 0) ) THEN
        imode0 = 0
        DO irr1 = 1, irr - 1
           imode0 = imode0 + npert (irr1)
        ENDDO
        IF (npert (irr) == 1) THEN
           WRITE( stdout, '(//,5x,"Representation #", i3," mode # ",i3)') &
                              irr, imode0 + 1
        ELSE
           WRITE( stdout, '(//,5x,"Representation #", i3," modes # ",8i3)') &
                              irr, (imode0+irr1, irr1=1,npert(irr))
        ENDIF
        !
        !    then for this irreducible representation we solve the linear system
        !
        IF (okvan) THEN
           ALLOCATE (int3 ( nhm, nhm, npert(irr), nat, nspin))
           IF (okpaw) ALLOCATE (int3_paw ( nhm, nhm, npert(irr), nat, nspin))
           IF (noncolin) ALLOCATE(int3_nc( nhm, nhm, npert(irr), nat, nspin))
        ENDIF
        WRITE( stdout, '(/,5x,"Self-consistent Calculation")')
        CALL solve_linter (irr, imode0, npert (irr), drhoscf)
        WRITE( stdout, '(/,5x,"End of self-consistent calculation")')
        !
        !   Add the contribution of this mode to the dynamical matrix
        !
        IF (convt) THEN
           CALL drhodv (imode0, npert (irr), drhoscf)
           !
           !   add the contribution of the modes imode0+1 -> imode+npe
           !   to the effective charges Z(Us,E) (Us=scf,E=bare)
           !
           IF (zue) CALL add_zstar_ue (imode0, npert (irr) )
           IF (zue.AND. okvan) CALL add_zstar_ue_us(imode0, npert (irr) )
           IF (zue) THEN
#ifdef __PARA
              call mp_sum ( zstarue0_rec, intra_pool_comm )
              call mp_sum ( zstarue0_rec, inter_pool_comm )
#endif
              zstarue0(:,:)=zstarue0(:,:)+zstarue0_rec(:,:)
           END IF
           !
           WRITE( stdout, '(/,5x,"Convergence has been achieved ")')
           done_irr (irr) = 1
        ELSE
           WRITE( stdout, '(/,5x,"No convergence has been achieved ")')
           CALL stop_ph (.FALSE.)
        ENDIF
        rec_code=20
        CALL write_rec('done_drhod',irr,0.0_DP,-1000,.false.,drhoscf,npert(irr))
        !
        IF (okvan) THEN
           DEALLOCATE (int3)
           IF (okpaw) DEALLOCATE (int3_paw)
           IF (noncolin) DEALLOCATE(int3_nc)
        ENDIF
        tcpu = get_clock ('PHONON')
        !
     ENDIF

  ENDDO
  DEALLOCATE (drhoscf)

  CALL stop_clock ('phqscf')
  RETURN
END SUBROUTINE phqscf
