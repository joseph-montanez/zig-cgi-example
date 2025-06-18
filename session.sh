#!/bin/bash

# --- Configuration ---
# Set the full path to your CGI binary
CGI_BINARY="./zig-out/bin/zig_cgi"

# Set the SCRIPT_NAME - the path the server uses to identify the script itself
# Often includes a directory like /cgi-bin/
SCRIPT_NAME_VALUE="/cgi-bin/$(basename "$CGI_BINARY")"

# Set the PATH_INFO - the extra path component requested *after* the script name
PATH_INFO_VALUE="/auth/register"

# --- POST Data Configuration ---
# Define your POST data here.
# For application/x-www-form-urlencoded, use key=value&key2=value2 format.
# Ensure values are URL-encoded if they contain special characters.
POST_DATA="full_name=John+Doe&email=john.doe%40example.com&password=mysecretpassword&password_confirm=mysecretpassword"

# Set the Content-Type for POST requests
CONTENT_TYPE_VALUE="application/x-www-form-urlencoded"

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

echo "--- Simulating POST Request ---"
echo "Binary:          $CGI_BINARY"
echo "Script Name:     $SCRIPT_NAME_VALUE"
echo "Path Info:       $PATH_INFO_VALUE"
echo "Content-Type:    $CONTENT_TYPE_VALUE"
echo "POST Data:       $POST_DATA"
echo "Simulated URI:   $SIMULATED_REQUEST_URI"
echo "------------------------------"
echo "Output:"
echo "" # Add a blank line for clarity before the output starts

# Calculate CONTENT_LENGTH
CONTENT_LENGTH_VALUE=${#POST_DATA}

# Set the necessary environment variables for a POST request
# and pipe the POST data to the binary's stdin.
REQUEST_METHOD="POST" \
SCRIPT_NAME="$SCRIPT_NAME_VALUE" \
PATH_INFO="$PATH_INFO_VALUE" \
CONTENT_TYPE="$CONTENT_TYPE_VALUE" \
CONTENT_LENGTH="$CONTENT_LENGTH_VALUE" \
REQUEST_URI="$SIMULATED_REQUEST_URI" \
SERVER_PROTOCOL="HTTP/1.1" \
GATEWAY_INTERFACE="CGI/1.1" \
"$CGI_BINARY" <<< "$POST_DATA"

# Capture the exit status of the CGI script
EXIT_STATUS=$?

echo "" # Add a blank line after the output
echo "--- Simulation Finished (Exit Status: $EXIT_STATUS) ---"

exit $EXIT_STATUS
