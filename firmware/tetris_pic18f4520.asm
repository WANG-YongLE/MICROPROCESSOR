;==============================================================================
;  File    : tetris_pic18f4520.asm
;  Project : 2026 Microprocessor Final Project - Tetris (UART version)
;  Target  : PIC18F4520, 10 MHz crystal, HSPLL -> Fosc = 40 MHz
;  Tool    : MPLAB X IDE v5.20 + MPASM (absolute code, no linker needed)
;
;  Hardware
;    RB0..RB5 : active-low push buttons with internal pull-ups
;               RB0 = left, RB1 = right, RB2 = soft drop
;               RB3 = hard drop, RB4 = rotate, RB5 = pause / restart
;    RC6/TX   : UART TX -> USB-TTL module RXD (115200, 8N1)
;    RC7/RX   : UART RX (not used by the game, keep connected or open)
;    Timer0   : 1 ms interrupt, used for key debounce and gravity timing
;
;  UART frame (fixed 208 bytes, little endian for score)
;    [0]      0xA5          start byte 1
;    [1]      0x5A          start byte 2
;    [2..201] board         10 columns x 20 rows
;                           byte value 0 = empty, 1 = fixed block, 2 = active
;    [202]    score high
;    [203]    score low
;    [204]    lines
;    [205]    level
;    [206]    state : 0 = running, 1 = paused, 2 = game over
;    [207]    checksum : XOR of byte 0 .. byte 206
;
;  Board layout : index = row * 10 + column, row 0 = top, row 19 = bottom
;  Piece table  : 7 pieces x 4 rotations x 4 rows, row mask bit0 = column 0
;==============================================================================

        LIST    P=18F4520
        #include <P18F4520.INC>

;------------------------------------------------------------------------------
; Configuration bits
;------------------------------------------------------------------------------
        CONFIG  OSC = HSPLL             ; HS crystal with 4x PLL
        CONFIG  FCMEN = OFF
        CONFIG  IESO = OFF
        CONFIG  PWRT = ON
        CONFIG  BOREN = OFF
        CONFIG  BORV = 3
        CONFIG  WDT = OFF
        CONFIG  WDTPS = 32768
        CONFIG  CCP2MX = PORTBE
        CONFIG  PBADEN = OFF            ; RB0..RB4 digital I/O at reset
        CONFIG  LPT1OSC = OFF
        CONFIG  MCLRE = ON              ; MCLR pin enabled
        CONFIG  STVREN = ON
        CONFIG  LVP = OFF               ; high voltage ICSP
        CONFIG  XINST = OFF
        CONFIG  DEBUG = OFF
        CONFIG  CP0 = OFF
        CONFIG  CP1 = OFF
        CONFIG  CP2 = OFF
        CONFIG  CP3 = OFF
        CONFIG  CPB = OFF
        CONFIG  CPD = OFF
        CONFIG  WRT0 = OFF
        CONFIG  WRT1 = OFF
        CONFIG  WRT2 = OFF
        CONFIG  WRT3 = OFF
        CONFIG  WRTC = OFF
        CONFIG  WRTB = OFF
        CONFIG  WRTD = OFF
        CONFIG  EBTR0 = OFF
        CONFIG  EBTR1 = OFF
        CONFIG  EBTR2 = OFF
        CONFIG  EBTR3 = OFF
        CONFIG  EBTRB = OFF

;------------------------------------------------------------------------------
; Variables (access RAM, 0x000 - 0x05F)
;------------------------------------------------------------------------------
        CBLOCK  0x000
tick_ms                 ; 1 ms counter, 0..9 -> 10 ms scan tick
hb_cnt                  ; heartbeat counter, 100 ms
key_last                ; previous raw key sample
key_stable              ; debounced key state (1 = pressed)
rep_l                   ; repeat counter for left
rep_r                   ; repeat counter for right
rep_d                   ; repeat counter for soft drop
act_flags               ; actions: b0 left b1 right b2 soft b3 hard
                        ;          b4 rotate b5 pause b6 gravity b7 heartbeat
snap                    ; snapshot of act_flags in main loop
frame_dirty             ; b0 = board changed, send a new frame
ptype                   ; current piece type 0..6
prot                    ; current rotation 0..3
px                      ; piece box x position 0..6
py                      ; piece box y position 0..19
chk_x                   ; collision test x
chk_y                   ; collision test y
chk_rot                 ; collision test rotation
new_rot                 ; rotation candidate
kick_idx                ; wall kick table index
gm_piece                ; get_mask parameter: piece
gm_rot                  ; get_mask parameter: rotation
tbl_ofs                 ; table offset temporary
t_r                     ; row loop index
t_c                     ; column loop index
t_mask                  ; current row mask
t_ny                    ; cell row under test
t_nx                    ; cell column under test
t_row                   ; get_mask parameter: row
score_h                 ; score high byte
score_l                 ; score low byte
line_count              ; total cleared lines
clear_cnt               ; number of line-clear events
level_num               ; level 1..10
grav_ms                 ; gravity period in 10 ms ticks
grav_cnt                ; gravity countdown in 10 ms ticks
game_state              ; 0 run, 1 pause, 2 game over
seed                    ; pseudo random seed
row_idx                 ; row scan index for line clear
n_lines                 ; lines cleared by the last lock
shift_k                 ; row shift loop index
shift_ofs               ; row shift offset
tmpx                    ; generic loop counter
checksum                ; UART checksum
tmp_raw                 ; raw key sample
        ENDC

board   EQU 0x100       ; 200 bytes : 10 x 20
txbuf   EQU 0x200       ; 208 bytes : complete UART frame copy buffer

;------------------------------------------------------------------------------
; Reset and interrupt vectors
;------------------------------------------------------------------------------
        ORG     0x0000
        goto    main

        ORG     0x0008
        goto    HighInt

;------------------------------------------------------------------------------
; High priority interrupt : Timer0 every 1 ms
;------------------------------------------------------------------------------
HighInt:
        push                            ; save W, STATUS, BSR

        bcf     INTCON,TMR0IF
        movlw   0xD8                    ; reload for 1.000 ms at 40 MHz
        movwf   TMR0H                   ; 65536 - 10000 = 0xD8F0
        movlw   0xF0
        movwf   TMR0L

        ; ---- 100 ms heartbeat : ask main loop to send a frame ----
        incf    hb_cnt,F
        movlw   d'100'
        cpfseq  hb_cnt
        bra     isr_scan
        clrf    hb_cnt
        bsf     act_flags,7

isr_scan:
        ; ---- key scan every 10 ms ----
        incf    tick_ms,F
        movlw   d'10'
        cpfseq  tick_ms
        bra     isr_done
        clrf    tick_ms
        call    scan_keys

        ; ---- gravity countdown after each 10 ms scan, only while running ----
        movf    game_state,W
        bnz     isr_done
        decf    grav_cnt,F
        bnz     isr_done
        movf    grav_ms,W
        movwf   grav_cnt
        bsf     act_flags,6

isr_done:
        pop                             ; restore BSR, STATUS, W
        retfie

;------------------------------------------------------------------------------
; scan_keys : called every 10 ms from the Timer0 interrupt
; Two identical samples are needed, so a key is debounced over 20 ms.
; Press edges set action flags. Left / right / soft drop auto-repeat.
;------------------------------------------------------------------------------
scan_keys:
        movf    PORTB,W
        andlw   0x3F                    ; RB0..RB5 only
        xorlw   0x3F                    ; invert: 1 = pressed
        movwf   tmp_raw

        xorwf   key_last,W              ; same as previous sample ?
        bz      keys_same
        movf    tmp_raw,W               ; new sample, wait for confirmation
        movwf   key_last
        return

keys_same:
        movf    tmp_raw,W
        xorwf   key_stable,W            ; state changed ?
        bz      keys_held
        ; ---- new pressed bits = raw AND (raw XOR stable) ----
        movf    tmp_raw,W
        xorwf   key_stable,W
        andwf   tmp_raw,W
        btfsc   WREG,0
        bsf     act_flags,0             ; left
        btfsc   WREG,1
        bsf     act_flags,1             ; right
        btfsc   WREG,2
        bsf     act_flags,2             ; soft drop
        btfsc   WREG,3
        bsf     act_flags,3             ; hard drop
        btfsc   WREG,4
        bsf     act_flags,4             ; rotate
        btfsc   WREG,5
        bsf     act_flags,5             ; pause / restart
        ; ---- clear repeat counters of released keys ----
        btfss   tmp_raw,0
        clrf    rep_l
        btfss   tmp_raw,1
        clrf    rep_r
        btfss   tmp_raw,2
        clrf    rep_d
        movf    tmp_raw,W
        movwf   key_stable

keys_held:
        ; ---- auto repeat : first after ~80 ms, then every ~30 ms ----
        btfss   key_stable,0
        bra     keys_chk_right
        incf    rep_l,F
        movlw   d'8'
        cpfseq  rep_l
        bra     keys_chk_right
        movlw   d'5'
        movwf   rep_l
        bsf     act_flags,0

keys_chk_right:
        btfss   key_stable,1
        bra     keys_chk_down
        incf    rep_r,F
        movlw   d'8'
        cpfseq  rep_r
        bra     keys_chk_down
        movlw   d'5'
        movwf   rep_r
        bsf     act_flags,1

keys_chk_down:
        btfss   key_stable,2
        bra     keys_exit
        incf    rep_d,F
        movlw   d'8'
        cpfseq  rep_d
        bra     keys_exit
        movlw   d'5'
        movwf   rep_d
        bsf     act_flags,2

keys_exit:
        return

;------------------------------------------------------------------------------
; board_ptr0 / board_ptr1 : W = byte offset, returns board + offset
;------------------------------------------------------------------------------
board_ptr0:
        movwf   FSR0L
        clrf    FSR0H
        movlw   LOW(board)
        addwf   FSR0L,F
        movlw   HIGH(board)
        addwfc  FSR0H,F
        return

board_ptr1:
        movwf   FSR1L
        clrf    FSR1H
        movlw   LOW(board)
        addwf   FSR1L,F
        movlw   HIGH(board)
        addwfc  FSR1H,F
        return

tx_ptr1:
        movwf   FSR1L
        clrf    FSR1H
        movlw   LOW(txbuf)
        addwf   FSR1L,F
        movlw   HIGH(txbuf)
        addwfc  FSR1H,F
        return

;------------------------------------------------------------------------------
; get_mask : W = row 0..3, returns 4-bit row mask of gm_piece / gm_rot
;------------------------------------------------------------------------------
get_mask:
        movwf   t_row
        movf    gm_piece,W
        mullw   d'16'                   ; piece * 16
        movf    PRODL,W
        movwf   tbl_ofs
        movf    gm_rot,W
        mullw   d'4'                    ; rotation * 4
        movf    PRODL,W
        addwf   tbl_ofs,W
        addwf   t_row,W                 ; + row
        movwf   TBLPTRL
        clrf    TBLPTRH
        clrf    TBLPTRU
        movlw   LOW(piece_table)
        addwf   TBLPTRL,F
        movlw   HIGH(piece_table)
        addwfc  TBLPTRH,F
        movlw   0x00
        addwfc  TBLPTRU,F
        tblrd   *
        movf    TABLAT,W
        return

;------------------------------------------------------------------------------
; get_kick : W = index 0..4, returns signed wall kick offset
;------------------------------------------------------------------------------
get_kick:
        movwf   TBLPTRL
        clrf    TBLPTRH
        clrf    TBLPTRU
        movlw   LOW(kick_tab)
        addwf   TBLPTRL,F
        movlw   HIGH(kick_tab)
        addwfc  TBLPTRH,F
        tblrd   *
        movf    TABLAT,W
        return

;------------------------------------------------------------------------------
; collision : test piece at chk_x, chk_y, chk_rot
; returns W = 0 (free), W = 1 (collision)
;------------------------------------------------------------------------------
collision:
        movf    ptype,W
        movwf   gm_piece
        movf    chk_rot,W
        movwf   gm_rot
        clrf    t_r

col_row_loop:
        movf    t_r,W
        call    get_mask
        andlw   0x0F
        movwf   t_mask
        bz      col_next_row
        clrf    t_c

col_col_loop:
        btfss   t_mask,0
        bra     col_next_col
        ; ---- row bounds ----
        movf    chk_y,W
        addwf   t_r,W
        movwf   t_ny
        movlw   d'20'
        cpfslt  t_ny                    ; skip if t_ny < 20
        retlw   1
        ; ---- column bounds ----
        movf    chk_x,W
        addwf   t_c,W
        movwf   t_nx
        movlw   d'10'
        cpfslt  t_nx                    ; skip if t_nx < 10
        retlw   1
        ; ---- board cell check ----
        movf    t_ny,W
        mullw   d'10'
        movf    t_nx,W
        addwf   PRODL,W
        call    board_ptr0
        movf    INDF0,W
        bnz     col_hit

col_next_col:
        rrncf   t_mask,F
        incf    t_c,F
        movlw   d'4'
        cpfseq  t_c
        bra     col_col_loop

col_next_row:
        incf    t_r,F
        movlw   d'4'
        cpfseq  t_r
        bra     col_row_loop
        retlw   0

col_hit:
        retlw   1

;------------------------------------------------------------------------------
; move_left / move_right
;------------------------------------------------------------------------------
move_left:
        movf    px,W
        bz      move_left_ret           ; already at the left wall
        addlw   0xFF                    ; px - 1
        movwf   chk_x
        movf    py,W
        movwf   chk_y
        movf    prot,W
        movwf   chk_rot
        call    collision
        btfsc   WREG,0
        bra     move_left_ret
        movf    chk_x,W
        movwf   px
        bsf     frame_dirty,0

move_left_ret:
        return

move_right:
        movf    px,W
        addlw   1
        movwf   chk_x
        movlw   d'7'
        cpfslt  chk_x                   ; skip if chk_x < 7
        bra     move_right_ret          ; box is 4 wide, max x = 6
        movf    py,W
        movwf   chk_y
        movf    prot,W
        movwf   chk_rot
        call    collision
        btfsc   WREG,0
        bra     move_right_ret
        movf    chk_x,W
        movwf   px
        bsf     frame_dirty,0

move_right_ret:
        return

;------------------------------------------------------------------------------
; do_rotate : rotate clockwise with simple wall kicks (0, -1, +1, -2, +2)
;------------------------------------------------------------------------------
do_rotate:
        movlw   d'1'                    ; O piece does not need rotation
        cpfseq  ptype
        bra     rot_go
        return

rot_go:
        movf    prot,W
        addlw   1
        andlw   0x03
        movwf   new_rot
        clrf    kick_idx

rot_kick_loop:
        movf    kick_idx,W
        call    get_kick
        addwf   px,W
        movwf   chk_x
        movlw   d'7'
        cpfslt  chk_x                   ; skip if chk_x < 7
        bra     rot_kick_next
        movf    py,W
        movwf   chk_y
        movf    new_rot,W
        movwf   chk_rot
        call    collision
        btfss   WREG,0
        bra     rot_ok

rot_kick_next:
        incf    kick_idx,F
        movlw   d'5'
        cpfseq  kick_idx
        bra     rot_kick_loop
        return

rot_ok:
        movf    chk_x,W
        movwf   px
        movf    new_rot,W
        movwf   prot
        bsf     frame_dirty,0
        return

;------------------------------------------------------------------------------
; soft_drop : one step down, lock when blocked
;------------------------------------------------------------------------------
soft_drop:
        movf    py,W
        addlw   1
        movwf   chk_y
        movf    px,W
        movwf   chk_x
        movf    prot,W
        movwf   chk_rot
        call    collision
        btfsc   WREG,0
        bra     soft_lock
        incf    py,F
        bsf     frame_dirty,0
        return

soft_lock:
        call    lock_piece
        return

;------------------------------------------------------------------------------
; hard_drop : move down until blocked, then lock
;------------------------------------------------------------------------------
hard_drop:
hard_loop:
        movf    py,W
        addlw   1
        movwf   chk_y
        movf    px,W
        movwf   chk_x
        movf    prot,W
        movwf   chk_rot
        call    collision
        btfsc   WREG,0
        bra     hard_lock
        incf    py,F
        bsf     frame_dirty,0
        bra     hard_loop

hard_lock:
        call    lock_piece
        return

;------------------------------------------------------------------------------
; lock_piece : copy the 4 cells into the board, clear lines, spawn next piece
;------------------------------------------------------------------------------
lock_piece:
        movf    ptype,W
        movwf   gm_piece
        movf    prot,W
        movwf   gm_rot
        clrf    t_r

lock_row_loop:
        movf    t_r,W
        call    get_mask
        andlw   0x0F
        movwf   t_mask
        bz      lock_next_row
        clrf    t_c

lock_col_loop:
        btfss   t_mask,0
        bra     lock_next_col
        movf    py,W
        addwf   t_r,W
        mullw   d'10'
        movf    px,W
        addwf   PRODL,W
        addwf   t_c,W
        call    board_ptr0
        movlw   0x01
        movwf   INDF0

lock_next_col:
        rrncf   t_mask,F
        incf    t_c,F
        movlw   d'4'
        cpfseq  t_c
        bra     lock_col_loop

lock_next_row:
        incf    t_r,F
        movlw   d'4'
        cpfseq  t_r
        bra     lock_row_loop

        call    clear_lines
        call    spawn_piece
        bsf     frame_dirty,0
        return

;------------------------------------------------------------------------------
; row_full : check row_idx, returns W = 1 when all 10 cells are occupied
;------------------------------------------------------------------------------
row_full:
        movf    row_idx,W
        mullw   d'10'
        movf    PRODL,W
        call    board_ptr0
        movlw   d'10'
        movwf   t_c

row_full_loop:
        movf    POSTINC0,W
        bz      row_full_no
        decf    t_c,F
        bnz     row_full_loop
        retlw   1

row_full_no:
        retlw   0

;------------------------------------------------------------------------------
; clear_lines : scan from bottom, clear full rows, update score / level
;------------------------------------------------------------------------------
clear_lines:
        clrf    n_lines
        movlw   d'19'
        movwf   row_idx

clear_scan:
        call    row_full
        btfss   WREG,0
        bra     clear_scan_up
        ; ---- full row found ----
        incf    n_lines,F
        movf    row_idx,W
        bz      clear_top_row
        ; ---- shift every row above down by one, bottom to top ----
        movf    row_idx,W
        movwf   shift_k

shift_row_loop:
        movf    shift_k,W
        mullw   d'10'
        movf    PRODL,W
        movwf   shift_ofs
        addlw   0xF6                    ; source = destination - 10
        call    board_ptr0
        movf    shift_ofs,W
        call    board_ptr1
        movlw   d'10'
        movwf   tmpx

shift_byte_loop:
        movf    POSTINC0,W
        movwf   POSTINC1
        decf    tmpx,F
        bnz     shift_byte_loop
        decf    shift_k,F
        movf    shift_k,W
        bnz     shift_row_loop

clear_top_row:
        movlw   LOW(board)
        movwf   FSR0L
        movlw   HIGH(board)
        movwf   FSR0H
        movlw   d'10'
        movwf   tmpx
clear_top_loop:
        clrf    POSTINC0
        decf    tmpx,F
        bnz     clear_top_loop
        bra     clear_scan              ; re-check the same row

clear_scan_up:
        movf    row_idx,W
        bz      clear_done
        decf    row_idx,F
        bra     clear_scan

clear_done:
        ; ---- score / level / speed ----
        movf    n_lines,W
        bz      clear_exit
        incf    clear_cnt,F
        ; level = (clear_cnt / 4) + 1
        movf    clear_cnt,W
        rrncf   WREG,W
        rrncf   WREG,W
        addlw   1
        movwf   level_num
        ; every 4 clear events, gravity period -5 ticks (50 ms), minimum 10 ticks (100 ms)
        movf    clear_cnt,W
        andlw   0x03
        bnz     clear_add_score
        movlw   d'10'
        cpfsgt  grav_ms                 ; skip if grav_ms > 10
        bra     clear_add_score
        movlw   d'5'
        subwf   grav_ms,F

clear_add_score:
        movf    n_lines,W
        addlw   0xFF
        bz      clear_add_100
        movf    n_lines,W
        addlw   0xFE
        bz      clear_add_300
        movf    n_lines,W
        addlw   0xFD
        bz      clear_add_500
        bra     clear_add_800

clear_add_100:
        movlw   0x64                    ; +100 = 0x0064
        addwf   score_l,F
        movlw   0x00
        addwfc  score_h,F
        bra     clear_score_done

clear_add_300:
        movlw   0x2C                    ; +300 = 0x012C
        addwf   score_l,F
        movlw   0x01
        addwfc  score_h,F
        bra     clear_score_done

clear_add_500:
        movlw   0xF4                    ; +500 = 0x01F4
        addwf   score_l,F
        movlw   0x01
        addwfc  score_h,F
        bra     clear_score_done

clear_add_800:
        movlw   0x20                    ; +800 = 0x0320
        addwf   score_l,F
        movlw   0x03
        addwfc  score_h,F

clear_score_done:
        movf    n_lines,W
        addwf   line_count,F

clear_exit:
        return

;------------------------------------------------------------------------------
; spawn_piece : pseudo random next piece at x = 3, y = 0
;------------------------------------------------------------------------------
spawn_piece:
        movf    seed,W
        mullw   d'5'
        movf    PRODL,W
        addlw   0x3D
        movwf   seed
        andlw   0x07
        movwf   ptype
        movlw   d'7'
        cpfseq  ptype
        bra     spawn_type_ok
        clrf    ptype                   ; map 7 to 0 (I piece)

spawn_type_ok:
        clrf    prot
        movlw   d'3'
        movwf   px
        clrf    py
        movf    px,W
        movwf   chk_x
        movf    py,W
        movwf   chk_y
        clrf    chk_rot
        call    collision
        btfss   WREG,0
        bra     spawn_done
        movlw   d'2'
        movwf   game_state              ; no room -> game over

spawn_done:
        bsf     frame_dirty,0
        return

;------------------------------------------------------------------------------
; reset_game : clear board and start a new game
;------------------------------------------------------------------------------
reset_game:
        movlw   LOW(board)
        movwf   FSR0L
        movlw   HIGH(board)
        movwf   FSR0H
        movlw   d'200'
        movwf   tmpx
reset_clear_loop:
        clrf    POSTINC0
        decf    tmpx,F
        bnz     reset_clear_loop

        clrf    score_h
        clrf    score_l
        clrf    line_count
        clrf    clear_cnt
        movlw   1
        movwf   level_num
        movlw   d'50'                   ; 500 ms gravity at the beginning (50 x 10 ms)
        movwf   grav_ms
        movwf   grav_cnt
        clrf    game_state
        movlw   0x2F
        addwf   seed,F                  ; change the piece sequence each game
        call    spawn_piece
        bsf     frame_dirty,0
        return

;------------------------------------------------------------------------------
; do_pause : running <-> paused, or restart when game over
;------------------------------------------------------------------------------
do_pause:
        movf    game_state,W
        bz      pause_on
        movlw   d'2'
        cpfseq  game_state
        bra     pause_off               ; state 1 -> resume
        call    reset_game              ; state 2 -> restart
        return

pause_on:
        movlw   1
        movwf   game_state
        bsf     frame_dirty,0
        return

pause_off:
        clrf    game_state
        movf    grav_ms,W
        movwf   grav_cnt
        bsf     frame_dirty,0
        return

;------------------------------------------------------------------------------
; overlay_piece : write value 2 for the active piece into txbuf
;------------------------------------------------------------------------------
overlay_piece:
        movf    ptype,W
        movwf   gm_piece
        movf    prot,W
        movwf   gm_rot
        clrf    t_r

overlay_row_loop:
        movf    t_r,W
        call    get_mask
        andlw   0x0F
        movwf   t_mask
        bz      overlay_next_row
        clrf    t_c

overlay_col_loop:
        btfss   t_mask,0
        bra     overlay_next_col
        movf    py,W
        addwf   t_r,W
        mullw   d'10'
        movf    px,W
        addwf   PRODL,W
        addwf   t_c,W
        call    tx_ptr1
        movlw   0x02
        movwf   INDF1

overlay_next_col:
        rrncf   t_mask,F
        incf    t_c,F
        movlw   d'4'
        cpfseq  t_c
        bra     overlay_col_loop

overlay_next_row:
        incf    t_r,F
        movlw   d'4'
        cpfseq  t_r
        bra     overlay_row_loop
        return

;------------------------------------------------------------------------------
; tx_byte : send W through the UART, blocking until TXREG is free
;------------------------------------------------------------------------------
tx_byte:
        btfss   PIR1,TXIF
        bra     tx_byte
        movwf   TXREG
        return

;------------------------------------------------------------------------------
; send_frame : build and send the complete 208 byte frame
;------------------------------------------------------------------------------
send_frame:
        movlw   0xA5
        call    tx_byte
        movlw   0x5A
        call    tx_byte
        movlw   0xFF                    ; preload checksum = A5 XOR 5A
        movwf   checksum

        ; ---- copy board to txbuf ----
        movlw   LOW(board)
        movwf   FSR0L
        movlw   HIGH(board)
        movwf   FSR0H
        movlw   LOW(txbuf)
        movwf   FSR1L
        movlw   HIGH(txbuf)
        movwf   FSR1H
        movlw   d'200'
        movwf   tmpx
send_copy_loop:
        movf    POSTINC0,W
        movwf   POSTINC1
        decf    tmpx,F
        bnz     send_copy_loop

        ; ---- draw active piece unless game over ----
        movlw   d'2'
        cpfseq  game_state
        call    overlay_piece

        ; ---- send 200 board bytes ----
        movlw   LOW(txbuf)
        movwf   FSR1L
        movlw   HIGH(txbuf)
        movwf   FSR1H
        movlw   d'200'
        movwf   tmpx
send_board_loop:
        movf    POSTINC1,W
        xorwf   checksum,F
        call    tx_byte
        decf    tmpx,F
        bnz     send_board_loop

        ; ---- score high / low, lines, level, state ----
        movf    score_h,W
        xorwf   checksum,F
        call    tx_byte
        movf    score_l,W
        xorwf   checksum,F
        call    tx_byte
        movf    line_count,W
        xorwf   checksum,F
        call    tx_byte
        movf    level_num,W
        xorwf   checksum,F
        call    tx_byte
        movf    game_state,W
        xorwf   checksum,F
        call    tx_byte

        ; ---- checksum ----
        movf    checksum,W
        call    tx_byte
        return

;------------------------------------------------------------------------------
; main : initialise hardware and run the game loop
;------------------------------------------------------------------------------
main:
        movlw   0x0F                    ; all analog inputs digital
        movwf   ADCON1
        movlw   0xFF                    ; PORTB all inputs (buttons)
        movwf   TRISB
        bcf     INTCON2,RBPU            ; enable PORTB pull-ups
        movlw   0x80                    ; RC7 input (RX), RC6 output (TX)
        movwf   TRISC

        ; ---- Timer0 : 16 bit, internal clock, no prescaler, 1 ms ----
        movlw   0x88
        movwf   T0CON
        movlw   0xD8
        movwf   TMR0H
        movlw   0xF0
        movwf   TMR0L
        bcf     INTCON,TMR0IF
        bsf     INTCON,TMR0IE

        ; ---- UART : 115200 8N1, BRG16 = 1, BRGH = 1, SPBRG = 86 ----
        movlw   0x28                    ; TXEN = 1, BRGH = 1
        movwf   TXSTA
        movlw   0x90                    ; SPEN = 1, CREN = 1
        movwf   RCSTA
        bsf     BAUDCON,BRG16
        movlw   d'86'
        movwf   SPBRG
        clrf    SPBRGH

        ; ---- table reads access program memory ----
        bcf     EECON1,CFGS
        bsf     EECON1,EEPGD

        ; ---- variables ----
        clrf    act_flags
        clrf    frame_dirty
        clrf    tick_ms
        clrf    hb_cnt
        clrf    key_last
        clrf    key_stable
        clrf    rep_l
        clrf    rep_r
        clrf    rep_d
        clrf    grav_cnt
        movlw   0x5A
        movwf   seed

        call    reset_game
        bsf     frame_dirty,0
        bsf     INTCON,GIE

main_loop:
        ; ---- take a snapshot of the action flags ----
        bcf     INTCON,GIE
        movf    act_flags,W
        movwf   snap
        clrf    act_flags
        bsf     INTCON,GIE

        ; ---- pause / restart works in every state ----
        btfss   snap,5
        bra     main_no_pause
        call    do_pause

main_no_pause:
        movf    game_state,W
        bz      main_running
        bra     main_send_check

main_running:
        btfss   snap,0
        bra     main_no_left
        call    move_left

main_no_left:
        btfss   snap,1
        bra     main_no_right
        call    move_right

main_no_right:
        btfss   snap,4
        bra     main_no_rot
        call    do_rotate

main_no_rot:
        btfss   snap,2
        bra     main_no_soft
        call    soft_drop

main_no_soft:
        btfss   snap,3
        bra     main_no_hard
        movf    game_state,W
        bnz     main_no_hard
        call    hard_drop

main_no_hard:
        btfss   snap,6
        bra     main_send_check
        movf    game_state,W
        bnz     main_send_check
        call    soft_drop

main_send_check:
        btfss   snap,7
        bra     main_dirty
        bsf     frame_dirty,0

main_dirty:
        btfss   frame_dirty,0
        bra     main_loop
        bcf     frame_dirty,0
        call    send_frame
        bra     main_loop

;------------------------------------------------------------------------------
; Program memory data tables
;------------------------------------------------------------------------------
kick_tab:
        db      0x00, 0xFF, 0x01, 0xFE, 0x02

; 7 pieces x 4 rotations x 4 rows, bit0 = left column
piece_table:
        db      0x00, 0x0F, 0x00, 0x00 ; I rot0  .... / #### / .... / ....
        db      0x04, 0x04, 0x04, 0x04 ; I rot1  ..#. / ..#. / ..#. / ..#.
        db      0x00, 0x00, 0x0F, 0x00 ; I rot2  .... / .... / #### / ....
        db      0x02, 0x02, 0x02, 0x02 ; I rot3  .#.. / .#.. / .#.. / .#..
        db      0x06, 0x06, 0x00, 0x00 ; O rot0  .##. / .##. / .... / ....
        db      0x06, 0x06, 0x00, 0x00 ; O rot1  .##. / .##. / .... / ....
        db      0x06, 0x06, 0x00, 0x00 ; O rot2  .##. / .##. / .... / ....
        db      0x06, 0x06, 0x00, 0x00 ; O rot3  .##. / .##. / .... / ....
        db      0x02, 0x07, 0x00, 0x00 ; T rot0  .#.. / ###. / .... / ....
        db      0x04, 0x0C, 0x04, 0x00 ; T rot1  ..#. / ..## / ..#. / ....
        db      0x00, 0x00, 0x0E, 0x04 ; T rot2  .... / .... / .### / ..#.
        db      0x00, 0x02, 0x03, 0x02 ; T rot3  .... / .#.. / ##.. / .#..
        db      0x06, 0x03, 0x00, 0x00 ; S rot0  .##. / ##.. / .... / ....
        db      0x04, 0x0C, 0x08, 0x00 ; S rot1  ..#. / ..## / ...# / ....
        db      0x00, 0x00, 0x0C, 0x06 ; S rot2  .... / .... / ..## / .##.
        db      0x00, 0x01, 0x03, 0x02 ; S rot3  .... / #... / ##.. / .#..
        db      0x03, 0x06, 0x00, 0x00 ; Z rot0  ##.. / .##. / .... / ....
        db      0x08, 0x0C, 0x04, 0x00 ; Z rot1  ...# / ..## / ..#. / ....
        db      0x00, 0x00, 0x06, 0x0C ; Z rot2  .... / .... / .##. / ..##
        db      0x00, 0x02, 0x03, 0x01 ; Z rot3  .... / .#.. / ##.. / #...
        db      0x01, 0x07, 0x00, 0x00 ; J rot0  #... / ###. / .... / ....
        db      0x0C, 0x04, 0x04, 0x00 ; J rot1  ..## / ..#. / ..#. / ....
        db      0x00, 0x00, 0x0E, 0x08 ; J rot2  .... / .... / .### / ...#
        db      0x00, 0x02, 0x02, 0x03 ; J rot3  .... / .#.. / .#.. / ##..
        db      0x04, 0x07, 0x00, 0x00 ; L rot0  ..#. / ###. / .... / ....
        db      0x04, 0x04, 0x0C, 0x00 ; L rot1  ..#. / ..#. / ..## / ....
        db      0x00, 0x00, 0x0E, 0x02 ; L rot2  .... / .... / .### / .#..
        db      0x00, 0x03, 0x02, 0x02 ; L rot3  .... / ##.. / .#.. / .#..

        END
