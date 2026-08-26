# Blind feature-design prompt

Add a configurable parser-engine recovery hook used when a reasoning boundary and tool
call arrive in the same streaming delta. Produce a design and verification plan before
editing. Expected paths are `vllm/parser/engine/parser_engine.py` and parser-engine tests.

Do not expose the answer key or other persona bodies to the design arm. The arm receives
only `base.md` plus personas selected from the expected paths with the `design` lens.
