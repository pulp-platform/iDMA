# Job Files

The basic verification of the iDMA IPs is based on file-based SystemVerilog testbenches. The files
read by the testbenches are called *job files*. A generation facility will be provided soon.
Contact the maintainers if you require the generator.

## Job File Format

The job files are just a sequence of individual jobs. There are different job formats depending on
the DUT. At the moment we support *1D jobs* and *ND jobs* to verify the backend and the nd-midend
respectively.

### 1D Format

- 1D length in bytes *unsigned int*
- Source address *hex*
- Destination address *hex*
- Source protocol index *int*
- Destination protocol index *int*
- Maximum source burst size in beats *unsigned int*
- Maximum destination burst size in beats *unsigned int*
- Decouple R - AW channels *bit*
- Decouple R - W  channels *bit*
- Number of errors *unsigned int*
- Followed by the address and type of error (if any are present)
  - *error type: \[r(ead)|w(rite)\]* *handler oprion: \[c(ontinue)|a(bort)\]* *address hex*

#### Error-free example

```
128
0x0
0x1000
0
0
256
256
0
0
0
```

#### Erroneous example

```
128
0x0
0x1000
0
0
256
256
0
0
1
rc0x4
```

### ND Format

- 1D length in bytes *unsigned int*
- Source address *hex*
- Destination address *hex*
- Source protocol index *int*
- Destination protocol index *int*
- Maximum source burst size in beats *unsigned int*
- Maximum destination burst size in beats *unsigned int*
- Decouple R - AW channels *bit*
- Decouple R - W  channels *bit*
- Number of errors *unsigned int*
- Repeat for the number of dimensions
  - Number of repetitions *int unsigned*
  - Source stride *hex*
  - Destination stride *hex*
- Followed by the address and type of error (if any are present)
  - *error type: \[r(ead)|w(rite)\]* *handler oprion: \[c(ontinue)|a(bort)\]* *address hex*

#### 4D example (no errors)

```
4
0x0
0x1000
0
0
256
256
0
0
2
0x100
0x200
2
0x1000
0x2000
1
0x10000
0x20000
0
```