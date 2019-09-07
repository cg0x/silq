# Silq

Silq is a high-level programming language for quantum computing with a strong static type system. More information: https://silq.ethz.ch

## Build Instructions

### GNU/Linux

#### Quick build

1. Run `dependencies.sh` to download the DMD D compiler and unzip it.

2. Run `build.sh` to build Silq.

##### Additional information

Silq is written in the D programming language. D compilers are available at http://dlang.org/download.html.

./build.sh will use DMD inside the Silq directory if it exists, otherwise it will attempt to use DMD from your path.

./build.sh creates a debug build.
./build-release creates a release build.

### Other platforms

The build instructions given here are for GNU/Linux and OSX. Silq can also be built on other platforms.
Feel free to write a pull request with working build scripts for your favourite platform.

### Example

```
$ ./dependencies.sh && ./build.sh
```

## Using Silq

Run `./silq example.slq`, where `example.slq` is a Silq source file.
The next section ("Quick language guide") briefly introduces the most important language features.

### Additional command-line options

Run `./silq --help` to display information about supported command-line options.
