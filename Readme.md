# Fully Distributed Chat system

This is the solution to a fully distributed chat system where all nodes must discover each other and chose a leader.

Init with:

```
bundle install
```

Run with:

```
ruby chatnode.rb <user_name>
```

### Depedencies

  This system depends on RabitMQ message broker for the nodes to communicate with each other. This must be installed on your local system and the server must be running on the default port. 

Run the server with:

```
rabbitmq-server 
```

### Aproach

 This is a distributed chat system that users RabitMQ to send messages to the nodes.

 - Each node is started by suppliying the user name for the node. When a node is started is sends a roll call anouncement to cause all the nodes to announce themselves. If a node is already using the user name the node will exit with an error message. 
 - The first node to start will become the leader. If the leader leaves an election is called to pick a new leader. The node that has been active the longest is chosen as the new leader.

### Commands

Each node can execute commands with the format: \command_name. The following commands are available:

- \list_users : displays the hash of users
- \state : displays the current connection state
- \is_leader : displays if the current node is the chat leader
- \current_leader : displays the name of the current chat leader


### Directives

The chat leader can issue certain directives that effect the other users. Each directive starts with a ! character. The directives are:

- !silence <user_name> : This will cause the targed user_name to not be able to talk
- !unsilence <user_name> : This allows the target user to talk again
- !remove <user_name> : This kicks the targed user off the system


### Exiting 
  To Exit the chat type: `bye` or `CTL-C `

### To Do
There are still some issues to deal with

- Two users trying to join with the same name at exactly the same time
- User Names are currently case sensative so 'Joe' and 'joe' would be two valid users




