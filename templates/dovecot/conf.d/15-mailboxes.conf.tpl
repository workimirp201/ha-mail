##############################################################################
# ha-mail :: /etc/dovecot/conf.d/15-mailboxes.conf
#
# Special-use folders, declared server-side.
#
# WHY THIS MATTERS ON A REPLICATED PAIR
# If the server does not declare special-use flags, each MUA invents its own
# names ("Sent Items", "Sent Messages", "Deleted Items"). Two clients on two
# nodes then create two different folders for the same purpose, dsync
# faithfully replicates BOTH, and the user ends up with a duplicated folder
# tree that looks exactly like a replication bug but is not one.
##############################################################################

namespace inbox {
  mailbox Drafts {
    special_use = \Drafts
    auto = subscribe
  }
  mailbox Sent {
    special_use = \Sent
    auto = subscribe
  }
  mailbox Junk {
    special_use = \Junk
    auto = subscribe
    # Retention for spam is a safe, local decision - the same rule runs on both
    # nodes and both reach the same conclusion about the same message, so the
    # expunges converge instead of fighting.
    autoexpunge = 30d
  }
  mailbox Trash {
    special_use = \Trash
    auto = subscribe
    autoexpunge = 60d
  }
  mailbox Archive {
    special_use = \Archive
    auto = subscribe
  }
  # Common aliases some clients look for before falling back to creating their
  # own. Declaring them without auto=create costs nothing and prevents the
  # duplicate-folder problem described above.
  mailbox "Sent Messages" {
    special_use = \Sent
  }
  mailbox "Sent Items" {
    special_use = \Sent
  }
  mailbox "Deleted Items" {
    special_use = \Trash
  }
  mailbox Spam {
    special_use = \Junk
  }
}
