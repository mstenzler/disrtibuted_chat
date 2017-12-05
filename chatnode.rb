require_relative './distributed_chat/node'

user_name = ARGV[0]
if (user_name)
  node = DistributedChat::Node.new(user_name)
  node.run
else
  puts "usage: ruby #{__FILE__} <user_name>"
end