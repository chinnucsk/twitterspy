module TwitterSpy

  class Tracker

    def initialize(server)
      @server=server
    end

    def update
      outbound=Hash.new { |h,k| h[k] = {}; h[k] }
      Track.todo.each do |track|
        puts "Fetching #{track.query} at #{Time.now.to_s}"
        summize_client = Summize::Client.new TwitterSpy::Config::USER_AGENT
        begin
          oldid = track.max_seen.to_i
          res = summize_client.query track.query, :since_id => oldid
          track.update_attributes(:last_update => DateTime.now,
            :max_seen => res.max_id,
            :next_update => compute_next_update(track))
          totx = oldid == 0 ? Array(res).last(5) : res.select { |x| x.id.to_i > oldid }
          track.users.select{|u| u.available? }.each do |user|
            totx.each do |msg|
              if user.language.nil? || msg.language.nil? || user.language == msg.language
                outbound[user.jid][msg.id] = msg if msg.id.to_i > user.min_id
              end
            end
          end
        rescue StandardError, Interrupt
          puts "Error fetching #{track.query}: #{$!}" + $!.backtrace.join("\n\t")
        end
      end
      outbound.each do |jid, msgs|
        puts "Sending #{msgs.size} messages to #{jid}"
        msgs.keys.sort.each do |msgk|
          msg = msgs[msgk]
          send_track_message jid, msg
        end
      end
    end

    def compute_next_update(track)
      # Give preference to common tracks.
      # Find the active user count for this track
      # XXX:  Getting a copy of the track to work around a DM bug.
      track = track.clone
      count = track.users(:active => true,
        :status.not => ['dnd', 'offline', 'unavailable']).size
      mins = [TwitterSpy::Config::WATCH_FREQ,
        TwitterSpy::Config::WATCH_FREQ - (count - 1)].min
      # But keep it above 0.
      mins = 1 if mins < 1
      if mins < TwitterSpy::Config::WATCH_FREQ
        puts "Reduced track freq for #{track.query} to #{mins} for #{count} active watchers"
      end
      DateTime.now + Rational(mins, 1440)
    end

    def user_link(user)
      linktext=user
      if user[0] == 64 # Does it start with @?
        user = user.gsub(/^@(.*)/, '\1')
      end
      %Q{<a href="http://twitter.com/#{user}">#{linktext}</a>}
    end

    def format_html_body(msg)
      user = user_link(msg.from_user)
      text = msg.text.gsub(/(\W*)(@[\w_]+)/) {|x| $1 + user_link($2)}.gsub(/&/, '&amp;')
      "#{user}: #{text}"
    end

    def format_plain_body(msg)
      "#{msg.from_user}: #{msg.text}"
    end

    def send_track_message(jid, msg)
      body = format_plain_body(msg)
      m = Jabber::Message::new(jid, body).set_type(:chat).set_id('1').set_subject("Track Message")

      # The html itself
      html = format_html_body(msg)
      begin
        REXML::Document.new "<html>#{html}</html>"

        h = REXML::Element::new("html")
        h.add_namespace('http://jabber.org/protocol/xhtml-im')

        # The body part with the correct namespace
        b = REXML::Element::new("body")
        b.add_namespace('http://www.w3.org/1999/xhtml')

        t = REXML::Text.new(format_html_body(msg), false, nil, true, nil, %r/.^/ )

        b.add t
        h.add b
        m.add_element(h)
      rescue REXML::ParseException
        puts "Nearly made bad html:  #{$!} (#{msg.text})"
        $stdout.flush
      end

      @server.deliver jid, m
    end

  end

end