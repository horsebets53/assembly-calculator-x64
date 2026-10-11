; The calculator core uses a private, SysV-style register convention on both
; platforms: RDI/RSI/RDX for integer arguments, XMM0 for a double, AL for the
; printf floating-argument count. It is NOT a Windows C-callable API.
; Only windows.asm crosses the Win64 ABI boundary (including entry from CRT).
IFDEF __WINDOWS__
EXTERN win_printf:PROC, win_strtod:PROC, win_fgets:PROC, win_fflush:PROC
ENDIF

CRT_CALL MACRO function
IFDEF __WINDOWS__
    call    win_&function
ELSE
    call    function
ENDIF
ENDM
