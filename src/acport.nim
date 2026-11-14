## Threaded Agent Client Protocol clients and agents over Linux stdio.

when not defined(linux):
  {.error: "ACPort stdio transport currently supports Linux only.".}

import
  acport/[api, auth_protocol, elicitation_protocol, events_protocol, host_protocol, protocol, session_protocol]

export api, auth_protocol, elicitation_protocol, events_protocol, host_protocol, protocol, session_protocol
