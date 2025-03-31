#!/bin/bash

# --- Configuration ---
# Set the full path to your CGI binary
CGI_BINARY="./zig-out/bin/zig_cgi"

# Set the SCRIPT_NAME - the path the server uses to identify the script itself
# Often includes a directory like /cgi-bin/
SCRIPT_NAME_VALUE="/cgi-bin/$(basename "$CGI_BINARY")"

# Set the PATH_INFO - the extra path component requested *after* the script name
PATH_INFO_VALUE="/auth/register"

# Set the query string you want to test (the part after the '?')
QUERY_STRING="param1=value1"

# --- Input Validation (Recommended) ---
if [[ ! -f "$CGI_BINARY" ]]; then
  echo "Error: CGI binary not found at '$CGI_BINARY'"
  exit 1
fi

if [[ ! -x "$CGI_BINARY" ]]; then
  echo "Error: CGI binary '$CGI_BINARY' is not executable."
  echo "Try running: chmod +x $CGI_BINARY"
  exit 1
fi

# --- Simulation ---
# Construct the simulated full request URI for completeness (optional but good practice)
SIMULATED_REQUEST_URI="${SCRIPT_NAME_VALUE}${PATH_INFO_VALUE}"
# Add query string to URI only if it's not empty
if [[ -n "$QUERY_STRING" ]]; then
  SIMULATED_REQUEST_URI="${SIMULATED_REQUEST_URI}?${QUERY_STRING}"
fi


echo "--- Simulating GET Request ---"
echo "Binary:         $CGI_BINARY"
echo "Script Name:    $SCRIPT_NAME_VALUE"
echo "Path Info:      $PATH_INFO_VALUE"
echo "Query String:   $QUERY_STRING"
echo "Simulated URI:  $SIMULATED_REQUEST_URI"
echo "------------------------------"
echo "Output:"
echo "" # Add a blank line for clarity before the output starts

# Set the necessary environment variables for a GET request
# including PATH_INFO and execute the binary.
REQUEST_METHOD="GET" \
SCRIPT_NAME="$SCRIPT_NAME_VALUE" \
PATH_INFO="$PATH_INFO_VALUE" \
QUERY_STRING="$QUERY_STRING" \
REQUEST_URI="$SIMULATED_REQUEST_URI" \
SERVER_PROTOCOL="HTTP/1.1" \
GATEWAY_INTERFACE="CGI/1.1" \
"$CGI_BINARY"

# Capture the exit status of the CGI script
EXIT_STATUS=$?

echo "" # Add a blank line after the output
echo "--- Simulation Finished (Exit Status: $EXIT_STATUS) ---"

exit $EXIT_STATUS