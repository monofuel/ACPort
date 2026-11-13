## Threaded Agent Client Protocol clients and agents over Linux stdio.

when not defined(linux):
  {.error: "ACPort stdio transport currently supports Linux only.".}

import
  acport/[api, elicitation_protocol, events_protocol, protocol, session_protocol]

export api, elicitation_protocol, events_protocol, protocol, session_protocol
