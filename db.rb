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

def ensure_teams_for_week(week)
  round = Round.find_one(:week => week)
  if( round.nil? )
    teams = Array.new
    teams << Team.new({:team_id => 75824, :name => "Oskar"})
    teams << Team.new({:team_id => 1753920, :name => "Anders"}) 
    teams << Team.new({:team_id => 3271, :name => "Magnus"})
    teams << Team.new({:team_id => 37951, :name => "Robert"})
    teams << Team.new({:team_id => 826402, :name => "Martin"})
    Round.create(:week => week, :teams => teams)
    fetch_teams(week)
    puts "Built teams for round #{week}"
  else
    puts "No need to fetch teams for round #{week}, already got data"
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

def get_players_to_update(week)
  player_ids = Array.new

  Round.find_by_week(week).teams.each do |team|
    team.players.collect { |p| player_ids << p.player_id }
  end

  player_ids.uniq!
end

def ensure_global_players(week, player_ids)
  player_ids.each { 
    |id| 
    if( GlobalPlayer.find_one(:player_id => id, :week => week).nil? )
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


def update_scores(week, player_ids)
  player_ids.each do |player_id|
    
    begin
      api_player = JSON.parse( RestClient.get "http://fantasy.premierleague.com/web/api/elements/#{player_id}/" )
    rescue => e
      puts "Couldnt get player #{player_id} because {e.message}, skipping..."
      next
    end
    
    player = GlobalPlayer.find_one({:player_id => player_id, :week => week})

    if( player.details != api_player["event_explain"] )
      real_change = false
      if( api_player["event_explain"].length != player.details.length )
        real_change = true
      else
        leng = api_player["event_explain"].length
        Array(0..leng-1).each do |cnt|
          if( api_player["event_explain"][cnt][2] != player.details[cnt][2] )
            real_change = true
            break
          end
        end
      end
      
      player.details = api_player["event_explain"]
      player.total_score = api_player["event_points"]
      player.updated = Time.new

      if( real_change )
        player.last_change = Time.new
        puts "There was a real change for player #{player_id}!"
      end

      player.save
      puts "Updated player #{player_id}, score is now #{api_player["event_points"]}"
    end

  end
end

regex_match = /.*:\/\/(.*):(.*)@(.*):(.*)\//.match(ENV['MONGOLAB_URI'])
host = regex_match[3]
port = regex_match[4]
db_name = regex_match[1]
pw = regex_match[2]
 
MongoMapper.connection = Mongo::Connection.new(host, port)
MongoMapper.database = db_name
MongoMapper.database.authenticate(db_name, pw)

current_week = 27

loop do

  puts "Fetching data at #{Time.new.inspect}"

  Round.ensure_index [[:week, 1]], :unique => true
  GlobalPlayer.ensure_index [[:player_id, 1]], :unique => true
  
  # build teams for current week
  ensure_teams_for_week(current_week)
    
  fetch_teams(current_week) unless ENV['force_fetch_teams'].nil?

  players_playing_this_week = get_players_to_update(current_week)

  ensure_global_players(current_week, players_playing_this_week)

  puts "Updating scores..."
  update_scores(current_week, players_playing_this_week)

  puts "Now sleeping for 2 minutes..."
  $stdout.flush
  sleep(2.minutes)
end
