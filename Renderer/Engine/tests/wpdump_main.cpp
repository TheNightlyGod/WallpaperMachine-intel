// wpdump <workshop_dir> [output.json]: prints (or writes) the JSON snapshot of one packed
// workshop item. Everything of substance lives in workshop_snapshot.cpp.
#include <iostream>

#include "workshop_snapshot.hpp"

int main(int argc, char** argv) {
    return wmsnap::runWpdump(argc, argv, std::cout, std::cerr);
}
