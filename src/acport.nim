## Threaded Agent Client Protocol clients and agents over Linux stdio.

when not defined(linux):
  {.error: "ACPort 1.0 stdio transport currently supports Linux only.".}

import
  acport/[api, protocol]

export api, protocol
