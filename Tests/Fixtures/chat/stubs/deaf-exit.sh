#!/bin/bash
# Never reads its stdin and leaves after a second: a long line still being written meets a closed pipe.
sleep 1
exit 0
