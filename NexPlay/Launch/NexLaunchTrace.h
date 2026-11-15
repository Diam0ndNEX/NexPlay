// NexPlay 8.7.5: launch trace. Each step appends one line to Documents/NexPlay-launch.txt (visible in the Files app),
// so a launch that dies before any log exists still shows how far it got.
#ifndef NEX_LAUNCH_TRACE_H
#define NEX_LAUNCH_TRACE_H
void nex_launch_mark(const char *step);
#endif
