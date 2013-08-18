require 'mongo'
require 'nokogiri'
require 'open-uri'
require 'mongo_mapper'
require 'pry'
require 'rest-client'
require 'json'

include Mongo

class Round 
  include MongoMapper::Document
  key :week, Integer, :unique => true
  many :teams
end

class Team
  include MongoMapper::EmbeddedDocument
  key :team_id, Integer
  key :name, String
  key :deduction, Integer
  many :players
end

class Player
  include MongoMapper::EmbeddedDocument
  key :player_id, Integer
  key :captain, Boolean
  key :vice_captain, Boolean
end

class GlobalPlayer
  include MongoMapper::Document
  key :player_id, Integer
  key :name, String
  key :shirt, String
  key :position, String
  key :week, Integer
  key :updated, Time
  key :last_change, Time
  key :total_score, Integer
  key :details, Array
end

def ensure_teams(week)
  round = Round.find_one(:week => week)
  if( round.nil? )
    teams = Array.new
    teams << Team.new({:team_id => 16665, :name => "Oskar"})
    teams << Team.new({:team_id => 55465, :name => "Anders"}) 
    teams << Team.new({:team_id => 1113, :name => "Magnus"})
    teams << Team.new({:team_id => 413689, :name => "Robert"})
    teams << Team.new({:team_id => 985532, :name => "Martin"})
    Round.create(:week => week, :teams => teams)
    fetch_teams(week)
    puts "Built teams for round #{week}"
  else
    puts "No need to build teams for round #{week}, already got team data"
  end
end

def fetch_teams(week)
  Round.find_by_week(week).teams.each do |t|
    # fetch team data
    team_url = "http://fantasy.premierleague.com/entry/#{t.team_id}/event-history/#{week}/"
    print "Fetching #{team_url}... "
    doc = Nokogiri::HTML(open(team_url))
    puts "Done"

    # determine deduction
    ded_elt = doc.css("dl.ismDefList.ismSBDefList").css("dd").last.to_s.gsub(/\s+/,"").match(/\(-(\d+)pts\)/)
    deduction = 0
    deduction = ded_elt[1].to_i unless ded_elt.nil?
    t.deduction = deduction

    # determine players
    players = Array.new
    Array(1..15).each do |cnt|
      scraped_player = JSON.parse(doc.css("#ismGraphical#{cnt}")[0]["class"][17..-2])
      
      player_id = scraped_player["id"].to_s
      captain = scraped_player["is_captain"]
      vice_captain = scraped_player["is_vice_captain"]

      players << Player.new(:player_id => player_id, :captain => captain, :vice_captain => vice_captain)
    end
    t.players = players

    t.save
  end
end

def get_players(week)
  player_ids = Array.new

  Round.find_by_week(week).teams.each do |team|
    team.players.collect { |p| player_ids << p.player_id }
  end

  player_ids.uniq!
end

def ensure_global_players(week, player_ids)
  player_ids.each { 
    |id| 
    if( GlobalPlayer.where( :player_id => id, :week => week ).count == 0 )
      puts "Creating global player #{id} for week #{week}"
      pl = JSON.parse( RestClient.get "http://fantasy.premierleague.com/web/api/elements/#{id}/" )
      GlobalPlayer.create( :player_id => id,
                           :name => pl["web_name"],
                           :team => pl["team_name"],
                           :shirt => pl["shirt_image_url"],
                           :position => pl["type_name"],
                           :week => week,
                           :updated => Time.new,
                           :last_change => Time.new,
                           :total_score => pl["event_points"],
                           :details => pl["event_explain"]
                           )
    end
  }
end

def determine_if_player_changed(current, new)
  real_change = false

  if( new.length != current.length )
    real_change = true
  else
    leng = new.length
    Array(0..leng-1).each do |cnt|
      if( new[cnt][2] != current[cnt][2] )
        real_change = true
        break
      end
    end
  end

  return real_change
end

def update_scores(week, player_ids)
  puts "Updating scores..."

  player_ids.each do |player_id|
    begin
      api_player = JSON.parse( RestClient.get "http://fantasy.premierleague.com/web/api/elements/#{player_id}/" )
    rescue => e
      puts "Couldnt get player #{player_id} because {e.message}, skipping..."
      next
    end
    
    current_player = GlobalPlayer.where(:player_id => player_id, :week => week).first

    if( current_player.details != api_player["event_explain"] )
      
      player_changed = determine_if_player_changed(current_player.details, api_player["event_explain"])
      
      current_player.details = api_player["event_explain"]
      current_player.total_score = api_player["event_points"]
      current_player.updated = Time.new

      if( player_changed )
        current_player.last_change = Time.new
        puts "Player #{player_id} was changed"
      end

      current_player.save
      puts "Updated player #{player_id}, score is now #{api_player["event_points"]}"
    end

  end
end



############ MAIN ENTRY POINT ###################

$stdout.sync = true

regex_match = /.*:\/\/(.*):(.*)@(.*):(.*)\//.match(ENV['MONGOLAB_URI'])
host = regex_match[3]
port = regex_match[4]
db_name = regex_match[1]
pw = regex_match[2]
 
MongoMapper.connection = Mongo::Connection.new(host, port)
MongoMapper.database = db_name
MongoMapper.database.authenticate(db_name, pw)

current_week = ENV['CURRENT_WEEK'].to_i

loop do
  puts "Fetching data at #{Time.new.inspect}"

  Round.ensure_index [[:week, 1]], :unique => true
  GlobalPlayer.ensure_index [[:player_id, 1]], :unique => true
  
  # build teams for current week
  ensure_teams(current_week)

  # rebuild teams if force_fetch_teams is set
  fetch_teams(current_week) unless ENV['force_fetch_teams'].nil?

  # get all players playing this week
  players_playing_this_week = get_players(current_week)

  # make sure we have saved all players playing this week for all teams
  ensure_global_players(current_week, players_playing_this_week)

  # update scores for all players playing this week
  update_scores(current_week, players_playing_this_week)

  puts "Now sleeping for 2 minutes..."
  sleep(2.minutes)

end

puts "Exiting..."

############ PROGRAM ENDS ########################

