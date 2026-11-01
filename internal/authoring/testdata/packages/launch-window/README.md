---
slug: launch-window
title: The Launch Window
type: code
position: 0
difficulty: 10
topics: constants, printing
---
# The Launch Window

Apogee's first rocket can lift off only while its launch window is open, and the flight
director wants the opening read out on the console.

A constant holds the number of seconds before liftoff when the window opens:

```go
const windowOpens = 90
```

## Assignment

Make `main` print exactly:

```text
Window opens at T-minus 90 seconds
```

Use the constant rather than writing 90 a second time.
