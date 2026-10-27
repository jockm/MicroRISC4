Instruction Nibble		Mnemonic			Bitform		Notes
==================		===============		========    ========================================================================================================== 
	0					LD Rr, Rl			0000rrll	Rr = Rl.  Thus 00 == LD R0, R0 which would be a NOP
	1					LD R0, imm4			0001iiii	R0 = imm4. 
	2					LD Rr, (Rl)			0010rrll	Rr = PEEK16(Rl)
	3					LD (Rr), Rl			0011rrll	POKE16(Rr, Rl)
	4					LD Rr, (--Rl)		0100rrll	Rr = PEEK16(--Rl)
	5					LD (Rr++), Rl		0101rrll	POKE16(Rr++, Rl)
	            		                	
	6					Add Rr, Rl			0110rrll	Rr += Rl
	7					Sub Rr, Rl			0111rrll	Rr -= Rl
	8					OR Rr, Rl			1000rrll	Rr |= Rl
	9					XOR Rr, Rl			1001rrll	Rr ^= Rl
	            		                	
	A					XTRA				1010????	Unassigned, consumes current and next byte 
	            		                	
	B					SHIFT.L Rr			101100rr	Rr = Rr LogicalShift_Left 1
	B*					SHIFT.R Rr			101101rr	Rr = Rr LogicalShift_Right 1
	B*					SHIFT.AR Rr			101110rr	Rr = Rr ArethmaticShift_Right 1
	B*					(unassigned)		101111rr	ignored
                		                	
	C					ROT.L Rr			110000rr	Rr = Rr Roate_Left 1
	C*					ROT.R Rr			110001rr	Rr = Rr Roate_Right 1
	C*					INC Rr				110010rr	Rr = Rr + 1
	C*					DEC Rr				110011rr	Rr = Rr - 1
	    				                	
	D					JMP.Z Rr, Rl		1101rrll	IF Rl == 0 THEN PC = Rr
	E					JMP.M Rr, Rl		1110rrll	IF Rl < 0 THEN PC = Rr
	    				                	
	F					JMP Rr				111100rr	PC = Rr
	F*					LINK Rr, R0			111101rr	R0 = PC + 1; PC = Rr
	F*  				PUSH8 Rr			111110rr	Rr = (Rr << 8) | NextByte 
	F*					TRAP Rr				111111rr	R0 = PC + 1; PC = FFF0 + (Rr & 0x0F)
	
	
AND 
OR
XOR	
	
Notes:
	R0 is most volatile register
	No flags

Memory Map
		0000 Code Origin Pointer?
		0001 Return Stack Pointer
		0002 Argument Stack Pointer
		0003 
		0004 
		0005 
		0006
		0007
		0008
		0009
		000A
		000B
		000C
		000D
		000E Serial Out
		000F Serial In

	Trap Table
		FFF0 Trap 0 (code origin)
		FFF1 Trap 1 
		FFF2 Trap 2 
		FFF3 Trap 3 
		FFF4 Trap 4 
		FFF5 Trap 5 
		FFF6 Trap 6 
		FFF7 Trap 7 
		FFF8 Trap 8 
		FFF9 Trap 9
		FFFA Trap 10
		FFFB Trap 11
		FFFC Trap 12
		FFFD Trap 13
		FFFE Trap 14
		FFFF Trap 15 (illegal instruction)



===============================
Common Macros

.macro LOAD16 reg, value
    PUSH8 %reg, >(%value)
    PUSH8 %reg, <(%value)
.endmacro

.macro PUSH reg
	LOAD16 R3, 0000
	LD R3, (R3)


===============================

0iiixxxx
1vvvvvvv

Multiply
Divide
Modulus

Other Rr, Rl (Next Byte) 



Code example, getting length of C style string
		...
		...
		LD.I R0, 04				; R3 = Argument Stack Pointer (2 bytes)
		LD R3, (R0)
		
		LD.I R0, 0				; R1 = 0xABCD (6 bytes)
		PUSH4 R0, A
		PUSH4 R0, B
		PUSH4 R0, C
		PUSH4 R0, D
		LD R1, R0
		
		LD (R3++), Rl			; Push address onto argument stack (1 byte)

		LD.I R0, 0				; R1 = STRLEN (6 bytes)
		PUSH4 R0, STRLEN.3
		PUSH4 R0, STRLEN.2
		PUSH4 R0, STRLEN.1
		PUSH4 R0, STRLEN.0
		LD R1, R0
				
		LINK R1, R0				; Call STRLEN (1 byte)
		
		LD R1, R0				; R1 = Result (R0)
		...
		...
		
		
STRLEN:
		LD R1, R0				; R1 = return address

		LD.I R0, 02				; R3 = Return stack pointer (2 bytes)
		LD R3, (R0)

		LD (R3++), R1			; Push the return address (1 byte)
		
		LD.I R0, 02				; Save the return address (2 Bytes)
		LD (R0), R3
		
		LD.I R0, 04				; R3 = Argument Stack Pointer (2 bytes)
		LD R3, (R0)
		
		LD R1, (--R3)			; R1 = address of the string (1 byte)
		
		LD.I R0, 04				; Save updated stack pointer (2 bytes)
		LD (R0)	 R3
		
		
		LD R0, 0				; R2 (return value) = 0 (2 bytes)
		LD R2, R0
		
STRLEN1:
		LD R3, (R1)				; Get the current byte of the string (1 byte)

		LD.I R0, 0				; R0 = STRLEN2 (6 bytes)
		PUSH4 R0, STRLEN2.3
		PUSH4 R0, STRLEN2.2
		PUSH4 R0, STRLEN2.1
		PUSH4 R0, STRLEN2.0
		
		JMP.Z R3, R0
		
		LD.I R0, 1
		ADD R2, R0
		
		LD.I R0, 0				; R0 = STRLEN1 (6 bytes)
		PUSH4 R0, STRLEN1.3
		PUSH4 R0, STRLEN1.2
		PUSH4 R0, STRLEN1.1
		PUSH4 R0, STRLEN1.0

		JMP R0
		
STRLEN2
		LD.I R0, 02				; R3 = Return stack pointer (2 bytes)
		LD R3, (R0)
		
		LD R1, (--R3)			; R1 = return address (1 byte)
		
		LD.I R0, 02				; Save the return address (2 Bytes)
		LD (R0), R3
		
		JMP R1


==========================
Ideas

TRAP4: 
	LD R1, (R0)
	INC R0
	INC R0
	JMP R0

Using Load8
		LD.I R0, 0				; R1 = 0xABCD (6 bytes)
		PUSH4 R0, A
		PUSH4 R0, B
		PUSH4 R0, C
		PUSH4 R0, D
		LD R1, R0
Option 1:
								; R1 = 0xABCD (5bytes)
		LD8 R0, AB 				; 2bytes
		PUSH4 R0, C
		PUSH4 R0, D
		LD R1, R0
Option 2:
		LD8 R1, AB				; R1 = 0xABCD (6 bytes)
		SHIFT.L4 R1
		SHIFT.L4 R1
		LD8 R1, CD
Option 3:
		PUSH8 R1, AB			; R1 = 0xABCD (4 bytes)
		PUSH8 R1, CD



-

Need:

Mult
Div
Mod

xxxxrrad

a	= arithmetic == 1
	= logical == 0
d	= left == 0
	= right