#!/bin/bash

# Key press test script - shows exactly what key codes are being captured

echo "Key Press Debugger"
echo "=================="
echo "Press a key and it will show the code. Press Ctrl+C to exit."
echo ""

# Save original terminal settings
orig_stty=$(stty -g 2>/dev/null)

while true; do
    echo "Waiting for key press..."
    
    # Set terminal to raw mode for this read
    stty -echo -icanon 2>/dev/null
    
    # Read one raw byte using dd
    key_byte=$(dd bs=1 count=1 2>/dev/null | od -An -td1 | tr -d ' \n')
    
    if [ -n "$key_byte" ]; then
        echo ""
        echo "========================================="
        echo "Raw byte ASCII code: $key_byte"
        
        case "$key_byte" in
            10) echo "KEY: ENTER (Line Feed)" ;;
            13) echo "KEY: ENTER (Carriage Return)" ;;
            32) echo "KEY: SPACE" ;;
            27) 
                echo "KEY: ESCAPE (checking for arrow keys...)"
                # Read potential arrow key sequence
                stty -echo -icanon min 0 time 1 2>/dev/null
                seq=""
                read -r -n2 -t0.1 seq 2>/dev/null
                if [ -n "$seq" ]; then
                    echo "  -> Escape sequence: ESC + '$seq'"
                    case "$seq" in
                        "[A") echo "  -> UP ARROW" ;;
                        "[B") echo "  -> DOWN ARROW" ;;
                        "[C") echo "  -> RIGHT ARROW" ;;
                        "[D") echo "  -> LEFT ARROW" ;;
                    esac
                fi
                ;;
            3) echo "KEY: Ctrl+C (exiting...)"; break ;;
            *) 
                if [ "$key_byte" -ge 32 ] && [ "$key_byte" -le 126 ]; then
                    char=$(printf "\\$(printf '%03o' "$key_byte")")
                    echo "KEY: '$char' (printable character)"
                else
                    echo "KEY: (non-printable control character)"
                fi
                ;;
        esac
        echo "========================================="
        echo ""
    fi
done

# Restore terminal on exit
stty "$orig_stty" 2>/dev/null
echo ""
echo "Exiting..."
