# Contributing

The report that helps most is a run on a machine I don't have: another laptop, a desktop, an AMD or Intel GPU, macOS 15. Open an issue with the machine, the GPU, the macOS build, and the `summary.md` of a pass. If a probe gives the wrong status on your machine (Fail for something that works, or Pass for something that is broken), add that probe's evidence file from the results folder, with serial numbers, network names and addresses taken out.

New probes are welcome. Keep them read-only where you can, put back anything they change, and mark them with `needs` so the runner asks first (`docs/HOW-IT-WORKS.md` has the fields). A probe that needs a tool from somewhere else gets a `req` path, so it is N/A instead of Fail on machines without it.

Pull requests: keep them small and say how you tested them. I read and test every PR before merging. AI-assisted PRs are fine as long as you can explain the change, which is the same bar I hold my own code to.

The code is ISC; contributions are under the same licence.
