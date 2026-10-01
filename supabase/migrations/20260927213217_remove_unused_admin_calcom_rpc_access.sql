-- Tutor creation and Cal.com assignment are handled by the protected admin Worker.
-- The browser panel does not call this database RPC directly.
revoke execute on function public.admin_assign_tutor_calcom(text, text, text, text)
from authenticated;
