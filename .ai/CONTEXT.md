# What this project is
cmpunlocker is a hardware research project targeting the NVIDIA CMP 170HX GPU. The CMP 170HX is a physically complete GA100 die — the same silicon as the A100 datacenter GPU — sold by Nvidia as a mining card with capabilities artificially restricted via OTP fuse configuration and firmware-enforced software locks. The restrictions are not due to absent hardware. The goal of this project is to restore those capabilities on the NVIDIA CMP 170HX.

# All code must pass the CI checks defined in .github/workflows. 
Before submitting any change, verify it would pass every status check defined there. Do not introduce code that would break any existing passing check, and do not modify the workflow files themselves unless explicitly asked to.

# Do not modify this file. 
This file exists purely to provide stable context to agents. It should never be edited, reformatted, or updated as part of any task.
