;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;PCGET -- Receive files via XMODEM from a PC
;
;Ohio Scientific Challenger III version, 4 MHz Z80. Supports built-in
;console port.  NOTE: 8080 Code!
;
;This CP/M program receives a file from a PC via a serial 
;port and writes it to a file on the CP/M system. The file
;transfer uses the XMODEM protocol. 
;
;Note this program is gutted from the Ward Christenson 
;MODEM program.
;
;Hacked together by Mike Douglas for the Horizon Computer
;Updated by Glitch Works for the SD Systems SBC-200
; Hacked again by Crawford Griffith for OSI C3
;
;Glitch Works customization and cleanup is:
;
;Copyright (c) 2019 The Glitch Works
;http://www.glitchwrks.com/
;
;Glitch Works customizations are released under the GNU GPLv3.
;
;Ver	Date	   Desc
;---    --------   ----------------------------------------
;1.0.2	2020-10-22 Changes for OSI-C3 (memory mapped ACIA)
;1.0.1  2019-06-27 Customized for the SD Systems SBC-200
;
;1.0    10/7/15	   Initial version. This code is almost the
;		   same as the Vector Graphic version as 
;		   both use the same 8251 ports for serial 
;		   I/O.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;Serial Port Equates
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;       EQUATES FOR CONSOLE PORT ACIA from OSILNKS.ASM
CRST    EQU     0F700H  			;RESET ADDRESS
CRST1   EQU     3       			;MASTER RESET
CRST2	EQU     10110001B			;8 	BIT WORD LENGTH
									;2 STOP BITS CLOCK DEVIDED BY 16
TTYISA	EQU     0FC00H  			;INPUT STATUS ADDRESS
TTYISB	EQU     1      				;INPUT STATUS BIT
TTYOSA	EQU     0FC00H  			;OUTPUT STATUS ADDRESS
TTYOSB	EQU     2       			;OUTPUT STATUS BIT
TTYIDA  EQU     0FC01H  			;INPUT DATA ADDRESS
TTYODA  EQU     0FC01H  			;OUTPUT DATA ADDRESS
CA6ISA  EQU     0FB05H  			;INPUT STATUS ADDRESS
CA6OSA  EQU     0FB05H  			;OUTPUT STATUS ADDRESS
CA6SR   EQU     0FB07H  			;INPUT STATUS REGISTER
CA6IDA  EQU     0FB03H  			;INPUT DATA ADDRESS
CA6ODA  EQU     0FB04H  			;OUTPUT DATA ADDRESS
CSTOP   EQU     13H     			;STOP CHAR
CSTRT   EQU     11H     			;START CHAR
CA9OSA  EQU     0F400H 				;LIST STATUS ADDRESS
CA9OSB  EQU     1       			;OUTPUT STATUS BIT
CA9ODA  EQU     0F402H  			;OUTPUT DATA ADDRESS
CA9SR   EQU     0F420H 				;STATUS REGISTER ?
IOBYTE  EQU     3

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;XMODEM Protocol Equates
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
SOH		EQU		1
EOT		EQU		4
ACK		EQU		6
NAK		EQU		21
CTRLC	EQU		3
LF		EQU		10
CR		EQU		13

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;CP/M 2 BDOS Equates
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
RDCON	EQU		1
WRCON	EQU		2
PRINT	EQU		9
CONST	EQU		11					;CONSOLE STAT
OPEN	EQU		15					;0FFH=NOT FOUND
CLOSE	EQU		16					;   "	"
SRCHF	EQU		17					;   "	"
SRCHN	EQU		18					;   "	"
ERASE	EQU		19					;NO RET CODE
READ	EQU		20					;0=OK, 1=EOF
WRITE	EQU		21					;0=OK, 1=ERR, 2=?, 0FFH=NO DIR SPC
MAKE	EQU		22					;0FFH=BAD
REN		EQU		23					;0FFH=BAD
STDMA	EQU		26
BDOS	EQU		5
REIPL	EQU		0
FCB		EQU		5CH					;DEFAULT FCB
PARAM1	EQU		FCB+1				;COMMAND LINE PARAMETER 1 IN FCB
PARAM2	EQU		PARAM1+16			;COMMAND LINE PARAMETER 2

	ORG	100H

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;START -- Get ready and begin the transfer
;
;This routine checks for the presence of a filename. If no
;filename is supplied, a help message is printed and we
;exit.
;
;Falls through to DOXFER
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
START:	LDA		PARAM1				;A=1st character of parameter 1
		CPI		' '					;make sure file name present
		JNZ		HAVEFN				;yes, have a file name
		LXI		D,MHELP				;display usage message
		MVI		C,PRINT
		CALL	BDOS
		RET							;return to CPM

HAVEFN:	MVI		B,CONDR				;Default to CONSOLE port
		LXI		D,MSENDC			;CONSOLE port send message

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;DOXFER -- Switch to a local stack and start transfer
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
DOXFER:	
		LXI		H,0					;HL=0
		DAD		SP					;HL=STACK FROM CP/M
		SHLD	STACK				;..SAVE IT
		LXI		SP,STACK			;SP=MY STACK
		XRA		A
		STA		SECTNO				;init sector number to zero
		MVI		C,PRINT				;print the send message
		CALL	BDOS				;PRINT ID MESSAGE

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;PURGE -- Consume garbage characters from the line
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
PURGE:	MVI		B,1					;times out after 1 second if no data
		CALL	RECV
		JC		RECEIVE$FILE		;line is clear, go receive the file
		CPI		CTRLC				;exit if abort requested
		JZ		ABORT
		JMP		PURGE

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;RECEIVE$FILE -- Receive the file via XMODEM
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
RECEIVE$FILE:
		CALL	ERASE$OLD$FILE
		CALL	MAKE$NEW$FILE
		MVI		A,NAK
		CALL	SEND				;SEND NAK

RECV$LOOP:
RECV$HDR:
		MVI		B,3					;3 SEC TIMEOUT
		CALL	RECV
		JNC		RHNTO				;NO TIMEOUT

RECV$HDR$TIMEOUT:
RECV$SECT$ERR:						;PURGE THE LINE OF INPUT CHARS
		MVI		B,1					;1 SEC W/NO CHARS
		CALL	RECV
		JNC		RECV$SECT$ERR 		;LOOP UNTIL SENDER DONE
		MVI		A,NAK
		CALL	SEND				;SEND NAK
		JMP		RECV$HDR

;GOT CHAR - MUST BE SOH OR CTRL-C TO ABORT

RHNTO:	CPI		SOH
		JZ		GOT$SOH
		CPI		CTRLC				;control-c to abort?
		JZ		ABORT
		CPI		EOT
		JZ		GOT$EOT
		JMP		RECV$SECT$ERR

GOT$SOH:
		MVI		B,1
		CALL	RECV
		JC		RECV$HDR$TIMEOUT
		MOV		D,A					;D=BLK #
		MVI		B,1
		CALL	RECV				;GET CMA'D SECT #
		JC		RECV$HDR$TIMEOUT
		CMA
		CMP		D					;GOOD SECTOR #?
		JZ		RECV$SECTOR
		JMP		RECV$SECT$ERR

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;RECV$SECTOR -- Get a sector via XMODEM
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
RECV$SECTOR:
		MOV		A,D					;GET SECTOR #
		STA		RSECTNO
		MVI		C,0					;INIT CKSUM
		LXI		H,80H				;POINT TO BUFFER

RECV$CHAR:
		MVI		B,1					;1 SEC TIMEOUT
		CALL	RECV				;GET CHAR
		JC		RECV$HDR$TIMEOUT
		MOV		M,A					;STORE CHAR
		INR		L					;DONE?
		JNZ		RECV$CHAR

									;VERIFY CHECKSUM
		MOV		D,C					;SAVE CHECKSUM
		MVI		B,1					;TIMEOUT
		CALL	RECV				;GET CHECKSUM
		JC		RECV$HDR$TIMEOUT
		CMP		D					;CHECK
		JNZ		RECV$SECT$ERR

		LDA		RSECTNO				;GOT A SECTOR, WRITE IF = 1+PREV SECTOR
		MOV		B,A					;SAVE IT
		LDA		SECTNO				;GET PREV
		INR		A					;CALC NEXT SECTOR #
		CMP		B					;MATCH?
		JNZ		DO$ACK

		LXI		D,FCB				;GOT NEW SECTOR - WRITE IT
		MVI		C,WRITE
		CALL	BDOS
		ORA		A
		JNZ		WRITE$ERROR
		LDA		RSECTNO
		STA		SECTNO				;UPDATE SECTOR #
DO$ACK:	MVI		A,ACK
		CALL	SEND
		JMP		RECV$LOOP

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;WRITE$ERROR -- Print file write error and exit
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
WRITE$ERROR:
		CALL	ERXIT
		DB	CR,LF,LF,'Error Writing File',CR,LF,'$'

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;GOT$EOT -- Handle end-of-transfer
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
GOT$EOT:
		MVI		A,ACK				;ACK THE EOT
		CALL	SEND
		LXI		D,FCB
		MVI		C,CLOSE
		CALL	BDOS
		INR		A
		JNZ		XFER$CPLT
		CALL	ERXIT
		DB		CR,LF,LF,'Error Closing File',CR,LF,'$'

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;ERASE$OLD$FILE -- Delete any existing file before transfer
;
;Caution. If the transfer fails, the old file will still
;have been deleted!
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
ERASE$OLD$FILE:
		LXI		D,FCB
		MVI		C,SRCHF				;SEE IF IT EXISTS
		CALL	BDOS
		INR		A					;FOUND?
		RZ							;NO, RETURN
ERAY:	LXI		D,FCB
		MVI		C,ERASE
		CALL	BDOS
		RET
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;MAKE$NEW$FILE -- Create a new empty file to write to
;
;This empty file will be what's left if the transfer fails,
;since we call ERASE$OLD$FILE first.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
MAKE$NEW$FILE:
		LXI		D,FCB
		MVI		C,MAKE
		CALL	BDOS
		INR		A					;FF=BAD
		RNZ							;OPEN OK

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;DIRFUL -- Print directory full error and exit
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
DIRFUL:	CALL	ERXIT
		DB		CR,LF,LF,'Error - Can',27H,'t Make File',CR,LF
		DB		'(directory must be full)',CR,LF,'$'

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;ERXIT -- Exit and print an error message
;
;The error message to be printed by this routine should be
;a $-terminated string following the call to ERXIT.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
ERXIT:	POP		D					;GET MESSAGE
		MVI		C,PRINT
		CALL	BDOS				;PRINT MESSAGE
EXIT:	LHLD	STACK				;GET ORIGINAL STACK
		SPHL						;RESTORE IT
		RET							;Back to CP/M

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;RECV -- XMODEM receive routine
;
;This routine contains code that will be modified at run
;time if a non-default port is selected for the transfer.
;
;Timeout is in B (number of seconds)
;Return sets carry if RECV timed out
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
RECV:	PUSH	D					;Save DE
MSEC:	LXI		D,248				;63 cycles, 4.032ms/wrap*248=1s (4MHz)

RCVSCR:	EQU		$+1					;Address of I/O port for the following IN
MWTI:	
		LDA     TTYISA  			;(13)console status check
       	ANI    	TTYISB				;(7) returns 0 if no character
        JNZ		MCHAR       		;(10) character present, go get it

		CPI		0					;(7) No char present, decrement countdown - cg ADDED
		CPI		0					;(7) No char present, decrement countdown
		CPI		0					;(7) waste some time
		DCR		E					;(5) COUNT DOWN
		JNZ		MWTI				;(10) FOR TIMEOUT
		DCR		D					;do msb every 256th time
		JNZ		MWTI
		DCR		B					;DCR # OF SECONDS
		JNZ		MSEC

		POP		D					;Receive timed out, restore DE
		STC							;Set carry flag to show timeout
		RET

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;MCHAR -- Process XMODEM character
;
;This routine contains code that will be modified at run
;time if a non-default port is selected for the transfer.
;Returns char in A, with carry cleared
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
RCVSDR:	EQU		$+1					;address of I/O port for the following IN - UNUSED
MCHAR:	
        LDA    	TTYIDA  			;GET DATA from the ACIA

		POP		D					;RESTORE DE
		PUSH	PSW					;CALC CHECKSUM
		ADD		C
		MOV		C,A
		POP		PSW
		ORA		A					;TURN OFF CARRY TO SHOW NO TIMEOUT
		RET

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;SEND -- Transmit an XMODEM character
;
;This routine contains code that will be modified at run
;time if a non-default port is selected for the transfer.
;A contains character
;C is the running checksum
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
SEND:	PUSH	PSW					;CHECK IF MONITORING OUTPUT
		ADD		C					;CALC CKSUM
		MOV		C,A

SNDSCR:	EQU		$+1					;address of I/O port for the following IN
SENDW:			
		LDA     TTYOSA  			;CHECK CONSOLE OUTPUT
        ANI     TTYOSB 				;STATUS AND LOOP
        JZ    	SENDW 				;UNTIL  READY
		
		POP		PSW					;GET CHAR

SNDSDR:	EQU		$+1					;address of I/O port for the following IN
	   	STA     TTYODA	
		RET

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;XFER$CPLT -- XMODEM transfer done, clean up
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
XFER$CPLT:
		CALL	ERXIT
		DB		CR,LF,LF,'Transfer Complete',CR,LF,'$'

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;ABORT -- Exit from a user abort
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
ABORT:	CALL	ERXIT
		DB		CR,LF,LF,'Transfer Aborted',CR,LF,'$'

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;Message Strings
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
MSENDC:	DB		'Send file using XMODEM on CONSOLE port...$'
MHELP:	DB		CR,LF,'PCGET v1.0.2 for OSI Challenger III',CR,LF,LF
		DB		'Receives a file from a PC through a serial port',CR,LF
		DB		'using the XMODEM protocol.',CR,LF,LF
		DB		'Usage: PCGET file.ext',CR,LF
		DB		'   CONSOLE port used by default',CR,LF,'$'

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;Variables and Storage Defines
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
		DS		40					;STACK AREA
STACK	DS		2					;STACK POINTER
RSECTNO	DS		1					;RECEIVED SECTOR NUMBER
SECTNO	DS		1					;CURRENT SECTOR NUMBER

	END
